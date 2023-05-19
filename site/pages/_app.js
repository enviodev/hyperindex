import "../styles/main.css";

// Note:
// Just renaming $$default to ResApp alone
// doesn't help FastRefresh to detect the
// React component, since an alias isn't attached
// to the original React component function name.
import ResApp from "../src/App.bs.js";

// The following code comes form here: https://levelup.gitconnected.com/improve-ux-of-your-next-js-app-in-3-minutes-with-page-loading-indicator-3a42211330u
import { useEffect } from "react";
import Router from "next/router";
import withGA from "next-ga";
import TagManager from "react-gtm-module";
import NProgress from "nprogress"; //nprogress module - // todo - tag: boilerplate copy pasta
import "nprogress/nprogress.css"; //styles of nprogress//Binding events.

Router.events.on("routeChangeStart", (_url, options) => {
  if (!options?.shallow) {
    NProgress.start();
  }
});
Router.events.on("routeChangeComplete", (_url, options) => {
  if (!options?.shallow) {
    NProgress.done();
  }
});
Router.events.on("routeChangeError", (_url, options) => {
  if (!options?.shallow) {
    NProgress.done();
  }
});

// todo
const googleAnalyticsMeasurementId = "";

// todo
const tagManagerArgs = {
  gtmId: "",
};

// Note:
// We need to wrap the make call with
// a Fast-Refresh conform function name,
// (in this case, uppercased first letter)
//
// If you don't do this, your Fast-Refresh will
// not work!
const App = (props) => {
  // if we don't have only one app instance we may end up with multiple metamask "on" handlers
  useEffect(() => {
    TagManager.initialize(tagManagerArgs);
  }, []);

  return (
    <div id={"app"}>
      <ResApp {...props} />
    </div>
  );
};

export default withGA(googleAnalyticsMeasurementId, Router)(App);
