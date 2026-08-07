import Foundation

/// The scripts that drive Facebook's own location picker.
///
/// Facebook will not take a coordinate as a URL parameter — measured, and it
/// silently serves the IP city instead (`docs/location-targeting.md` §4). But
/// the "Change location" dialog has a centring arrow that asks the *browser*
/// where it is, and it accepts whatever answer it gets: fed London from a
/// Toronto session behind a San Francisco IP, it resolved to London (§5a, and
/// §5b for the same result inside `WKWebView`).
///
/// So Facebook does the place resolution, and the app never guesses a slug.
enum GeoPickerScripts {
    /// Replaces `navigator.geolocation` with one that answers from
    /// `window.__geoFeed`, injected at document start.
    ///
    /// Two things make this the right shape rather than granting the web view
    /// real location access:
    ///
    /// * WKWebView's own Geolocation support has never been dependable, so
    ///   relying on it would make this work by luck.
    /// * `__geoFeed` starts **null**, and every call errors until the app sets
    ///   it. Facebook cannot obtain a position at a moment of its choosing —
    ///   only the one the app hands over, at the moment it hands it over. The
    ///   web view has no location permission of its own to leak.
    static let feeder = """
    (function(){
      if (window.__geoFedHooked) return;
      window.__geoFedHooked = true;
      window.__geoFeed = null;
      window.__geoFedCalls = 0;
      function position() {
        return {
          coords: {
            latitude: window.__geoFeed.lat, longitude: window.__geoFeed.lon,
            accuracy: 20, altitude: null, altitudeAccuracy: null,
            heading: null, speed: null
          },
          timestamp: Date.now()
        };
      }
      function getCurrentPosition(ok, err) {
        window.__geoFedCalls++;
        if (!window.__geoFeed) {
          // PERMISSION_DENIED — the honest answer when the app hasn't offered
          // a coordinate, and the one a page handles gracefully.
          if (err) err({ code: 1, message: 'denied' });
          return;
        }
        setTimeout(function(){ ok(position()); }, 0);
      }
      function watchPosition(ok, err) { getCurrentPosition(ok, err); return 1; }
      var impl = { getCurrentPosition: getCurrentPosition,
                   watchPosition: watchPosition,
                   clearWatch: function(){} };
      var g = navigator.geolocation;
      if (!g) {
        Object.defineProperty(navigator, 'geolocation', { value: impl, configurable: true });
      } else {
        Object.defineProperty(g, 'getCurrentPosition', { value: getCurrentPosition, writable: true, configurable: true });
        Object.defineProperty(g, 'watchPosition', { value: watchPosition, writable: true, configurable: true });
      }
    })();
    """

    /// Arms the feed with a coordinate. Nothing reads it until the arrow is
    /// clicked, so this is safe to call before the dialog exists.
    static func arm(latitude: Double, longitude: Double) -> String {
        """
        (function(){
          window.__geoFeed = { lat: \(latitude), lon: \(longitude) };
          return JSON.stringify({ armed: !!window.__geoFedHooked });
        })()
        """
    }

    /// Opens the "Change location" dialog from the header pill.
    ///
    /// The pill's units follow the *place*, not the viewer — a Canadian
    /// location renders "Toronto · 8 km" — and matching only `mi` once made a
    /// perfectly good pill invisible.
    static let openDialog = """
    (function(){
      var btn = Array.prototype.slice.call(document.querySelectorAll('div[role="button"]'))
        .filter(function(e){ var t = (e.textContent||'').trim();
                             return /·\\s*\\d+\\s*(mi|km)/i.test(t) && t.length < 80; })[0];
      if (!btn) return JSON.stringify({ opened: false });
      btn.click();
      return JSON.stringify({ opened: true, was: btn.textContent.trim() });
    })()
    """

    /// Clicks the centring arrow, which calls the shim and waits on it.
    static let clickArrow = """
    (function(){
      var arrow = document.querySelector('[aria-label="Marketplace geolocation picker"]');
      if (!arrow) return JSON.stringify({ clicked: false });
      var before = window.__geoFedCalls;
      arrow.click();
      return JSON.stringify({ clicked: true, called: window.__geoFedCalls > before });
    })()
    """

    /// Commits the resolved place.
    static let apply = """
    (function(){
      var apply = document.querySelector('[aria-label="Apply"]');
      if (!apply) return JSON.stringify({ applied: false });
      apply.click();
      return JSON.stringify({ applied: true });
    })()
    """

    /// The pill's place name and the URL, after everything has settled. These
    /// are the two things worth keeping: the name to show the user, the URL
    /// segment to search with.
    static let readResult = """
    (function(){
      var pill = Array.prototype.slice.call(document.querySelectorAll('div[role="button"],span'))
        .map(function(e){ return (e.textContent||'').trim(); })
        .filter(function(t){ return /·\\s*\\d+\\s*(mi|km)/i.test(t) && t.length < 60; })[0] || null;
      var name = pill ? pill.split('·')[0].trim() : null;
      // The raw pill goes back untouched as well as parsed — `DesktopLocationPill`
      // reads the radius out of it, and an unexpected format is only
      // debuggable if the original text survives (probe checklist §2).
      return JSON.stringify({ name: name, pill: pill, url: location.href });
    })()
    """
}
