module Link = Next.Link

let floatingMenuZoomStyle = shouldDisplay => {
  Styles.floatingMenuZoomStyle["floating-menu"] ++ (
    shouldDisplay ? " " ++ Styles.floatingMenuZoomStyle["should-display"] : ""
  )
}

let hamburgerSvg = () =>
  <svg
    className={"transition-transform duration-500 delay-0 ease-in-out hover:rotate-180"}
    height="32px"
    id="Layer_1"
    version="1.1"
    fill={"#" ++ "ffffff"}
    width="32px">
    <path
      d="M4,10h24c1.104,0,2-0.896,2-2s-0.896-2-2-2H4C2.896,6,2,6.896,2,8S2.896,10,4,10z M28,14H4c-1.104,0-2,0.896-2,2  s0.896,2,2,2h24c1.104,0,2-0.896,2-2S29.104,14,28,14z M28,22H4c-1.104,0-2,0.896-2,2s0.896,2,2,2h24c1.104,0,2-0.896,2-2  S29.104,22,28,22z"
    />
  </svg>

let closeSvg = () =>
  <svg
    height="32px"
    className={"transition-transform duration-500 delay-0 ease-in-out hover:rotate-180"}
    viewBox="0 0 512 512"
    fill={"#" ++ "222222"}
    width="32px">
    <path
      d="M437.5,386.6L306.9,256l130.6-130.6c14.1-14.1,14.1-36.8,0-50.9c-14.1-14.1-36.8-14.1-50.9,0L256,205.1L125.4,74.5  c-14.1-14.1-36.8-14.1-50.9,0c-14.1,14.1-14.1,36.8,0,50.9L205.1,256L74.5,386.6c-14.1,14.1-14.1,36.8,0,50.9  c14.1,14.1,36.8,14.1,50.9,0L256,306.9l130.6,130.6c14.1,14.1,36.8,14.1,50.9,0C451.5,423.4,451.5,400.6,437.5,386.6z"
    />
  </svg>

type navItem = {
  label: string,
  link: string,
  isDifferentDomain: bool,
}

let navItems: array<navItem> = [
  {
    label: "Docs",
    link: Routes.docs,
    isDifferentDomain: true,
  },
  {
    label: "Use cases",
    link: Routes.useCases,
    isDifferentDomain: false,
  },
  {
    label: "Careers",
    link: Routes.careers,
    isDifferentDomain: false,
  },
  {
    label: "Support",
    link: Routes.support,
    isDifferentDomain: false,
  },
]

@react.component
let make = () => {
  let (isOpen, setIsOpen) = React.useState(_ => false)

  let router = Next.Router.useRouter()

  let activeHighlight = path => {
    router.pathname == path ? "underline" : ""
  }

  <div className={"w-full py-1 flex items-center" ++ Styles.generalStyles["logo-container"]}>
    <nav className="mx-auto w-full max-w-7xl py-2 h-12 flex justify-between items-center text-sm">
      <Link href="/">
        <div className={Styles.generalStyles["logo-container"]}>
          <div className="relative h-8 md:h-7">
            <Logo />
          </div>
        </div>
      </Link>
      //   desktop nav
      <div className="hidden md:hidden nav:block justify-end w-2/3">
        <div className="md:flex text-base items-center justify-end">
          {navItems
          ->Array.map(navItem =>
            navItem.isDifferentDomain
              ? <div className="px-7">
                  <Hyperlink className=" hover:bg-white" href=navItem.link openInNewTab=true>
                    {navItem.label->React.string}
                  </Hyperlink>
                </div>
              : <Link href={navItem.link}>
                  <span className={`px-7 hover:bg-white ${navItem.link->activeHighlight}`}>
                    {navItem.label->React.string}
                  </span>
                </Link>
          )
          ->React.array}
          <LightDarkModeToggle />
        </div>
      </div>
      //   mobile nav
      <div className="flex w-2/3 text-base items-center justify-end visible nav:hidden">
        <div
          className="z-50 absolute top-0 right-0 m-6" onClick={_ => setIsOpen(isOpen => !isOpen)}>
          {isOpen ? <> {closeSvg()} </> : hamburgerSvg()}
        </div>
        <div className={floatingMenuZoomStyle(isOpen)}>
          <div
            className={Styles.floatingMenuZoomStyle["zoom-in-effect"] ++
            (isOpen
              ? " " ++ Styles.floatingMenuZoomStyle["should-display-zoom-in-effect"]
              : "") ++ " flex flex-col text-3xl text-white"}>
            {navItems
            ->Array.map(navItem =>
              navItem.isDifferentDomain
                ? <div
                    className="p-2 bg-black"
                    onClick={_ => {
                      setIsOpen(_ => false)
                    }}>
                    <Hyperlink href=navItem.link openInNewTab=true>
                      {navItem.label->React.string}
                    </Hyperlink>
                  </div>
                : <div
                    onClick={_ => {
                      router->Next.Router.push(navItem.link)
                      setIsOpen(_ => false)
                    }}
                    className={`p-2 bg-black m-2 ${navItem.link->activeHighlight}`}>
                    {navItem.label->React.string}
                  </div>
            )
            ->React.array}
          </div>
        </div>
      </div>
    </nav>
  </div>
}
