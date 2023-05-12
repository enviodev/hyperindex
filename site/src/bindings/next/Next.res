module GetServerSideProps = {
  module Req = {
    type t
  }

  module Res = {
    type t

    @send external setHeader: (t, string, string) => unit = "setHeader"
    @send external write: (t, string) => unit = "write"
    @send external end: t => unit = "end"
  }

  // See: https://github.com/zeit/next.js/blob/canary/packages/next/types/index.d.ts
  type context<'props, 'params, 'previewData> = {
    params: 'params,
    query: Js.Dict.t<string>,
    preview: option<bool>, // preview is true if the page is in the preview mode and undefined otherwise.
    previewData: Js.Nullable.t<'previewData>,
    req: Req.t,
    res: Res.t,
  }

  // The definition of a getServerSideProps function
  type t<'props, 'params, 'previewData> = context<'props, 'params, 'previewData> => Js.Promise.t<{
    "props": 'props,
  }>
}

module GetStaticProps = {
  // See: https://github.com/zeit/next.js/blob/canary/packages/next/types/index.d.ts
  type context<'props, 'params, 'previewData> = {
    params: 'params,
    preview: option<bool>, // preview is true if the page is in the preview mode and undefined otherwise.
    previewData: Js.Nullable.t<'previewData>,
  }

  // The definition of a getStaticProps function
  type t<'props, 'params, 'previewData> = context<'props, 'params, 'previewData> => Js.Promise.t<{
    "props": 'props,
  }>
}

module GetStaticPaths = {
  // 'params: dynamic route params used in dynamic routing paths
  // Example: pages/[id].js would result in a 'params = { id: string }
  type path<'params> = {params: 'params}

  type return<'params> = {
    paths: array<path<'params>>,
    fallback: bool,
  }

  // The definition of a getStaticPaths function
  type t<'params> = unit => Js.Promise.t<return<'params>>
}

module Link = {
  @module("next/link") @react.component
  external make: (
    ~href: string,
    ~_as: string=?,
    ~prefetch: bool=?,
    ~replace: option<bool>=?,
    ~shallow: option<bool>=?,
    ~passHref: option<bool>=?,
    ~children: React.element,
  ) => React.element = "default"
}

module Router = {
  /*
      Make sure to only register events via a useEffect hook!
 */
  module Events = {
    type t

    @send
    external on: (
      t,
      @string
      [
        | #routeChangeStart(string => unit)
        | #routeChangeComplete(string => unit)
        | #hashChangeComplete(string => unit)
      ],
    ) => unit = "on"

    @send
    external off: (
      t,
      @string
      [
        | #routeChangeStart(string => unit)
        | #routeChangeComplete(string => unit)
        | #hashChangeComplete(string => unit)
      ],
    ) => unit = "off"
  }

  type router = {
    route: string,
    asPath: string,
    events: Events.t,
    pathname: string,
    query: Js.Dict.t<string>,
    isReady: bool,
  }

  type pathObj = {
    pathname: string,
    query: Js.Dict.t<string>,
  }

  @send external push: (router, string) => unit = "push"
  type pushOptions = {shallow: bool, scroll: bool}
  @send external pushOptions: (router, string, option<unit>, pushOptions) => unit = "push"
  let pushShallow = (routerObj, queryString) =>
    pushOptions(routerObj, queryString, None, {shallow: true, scroll: true})
  @send external pushObj: (router, pathObj) => unit = "push"
  @send external pushObjOptions: (router, pathObj, option<unit>, pushOptions) => unit = "push"
  let pushObjShallow = (routerObj, pathObj) =>
    pushObjOptions(routerObj, pathObj, None, {shallow: true, scroll: true})
  let pushObjShallowNoScroll = (routerObj, pathObj) =>
    pushObjOptions(routerObj, pathObj, None, {shallow: true, scroll: false})

  @send external pushPromise: (router, string) => Promise.t<unit> = "push"
  @send external pushObjPromise: (router, pathObj) => Promise.t<unit> = "push"
  @send
  external pushObjOptionsPromise: (router, pathObj, option<unit>, pushOptions) => Promise.t<unit> =
    "push"
  @send
  external pushOptionsPromise: (router, string, option<unit>, pushOptions) => Promise.t<unit> =
    "push"

  @module("next/router") external useRouter: unit => router = "useRouter"

  @send external replace: (router, string) => unit = "replace"
  @send external replaceObj: (router, pathObj) => unit = "replace"

  @send external replacePromise: (router, string) => Promise.t<unit> = "replace"
  @send
  external replaceObjOptionsPromise: (
    router,
    pathObj,
    option<unit>,
    pushOptions,
  ) => Promise.t<unit> = "replace"
  @send
  external replaceOptionsPromise: (router, string, option<unit>, pushOptions) => Promise.t<unit> =
    "replace"
}

module Head = {
  @module("next/head") @react.component
  external make: (~children: React.element) => React.element = "default"
}

module Error = {
  @module("next/error") @react.component
  external make: (~statusCode: int, ~children: React.element) => React.element = "default"
}

module Dynamic = {
  @deriving(abstract)
  type options = {
    @optional
    ssr: bool,
    @optional
    loading: unit => React.element,
  }

  /* * Test * */
  @module("next/dynamic")
  external dynamic: (unit => Js.Promise.t<'a>, options) => 'a = "default"

  @val external import_: string => Js.Promise.t<'a> = "import"
}

module Image = {
  // let layoutOptions =
  type loaderProps = {
    src: string,
    width: string,
    quality: string,
  }

  type onLoadingCompleteProps = {
    naturalWidth: string,
    naturalHeight: string,
  }
  @module("next/legacy/image") @react.component
  external make: (
    ~src: string,
    ~width: string=?,
    ~height: string=?,
    ~alt: string=?,
    ~layout: [#intrinsic | #fixed | #responsive | #fill | #raw]=?,
    ~loader: loaderProps => string=?,
    ~sizes: string=?,
    ~quality: int=?,
    ~priority: bool=?,
    ~placeholder: [#blur | #empty]=?,
    ~style: ReactDOM.style=?,
    ~objectFit: string=?,
    ~objectPosition: string=?,
    ~onLoadingComplete: onLoadingCompleteProps => unit=?,
    ~loading: [#eager | #"lazy"]=?,
    ~blurDataURL: string=?,
    ~lazyBoundary: string=?,
    ~lazyRoot: React.ref<'value>=?,
    ~unoptimized: bool=?,
    ~className: string=?,
    // not yet in the docs but seems to work
    ~onError: ReactEvent.Media.t => unit=?,
  ) => React.element = "default"
}
