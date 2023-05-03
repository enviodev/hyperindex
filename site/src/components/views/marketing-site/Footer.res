open Typography

@react.component
let make = () => {
  <section className="flex flex-col justify-between items-center ">
    <div className="flex flex-col md:flex-row leading-8 font-thin">
      <div className="flex flex-col m-4">
        <Logo />
      </div>
      <div className="flex flex-col m-4">
        <Heading4> {"Shipper resources"->React.string} </Heading4>
        <Hyperlink href="#" openInNewTab=true> {"Quick Start Guide"->React.string} </Hyperlink>
        <Hyperlink href="#" openInNewTab=true> {"Developer Docs"->React.string} </Hyperlink>
        <Hyperlink href="#" openInNewTab=true> {"Use Cases"->React.string} </Hyperlink>
      </div>
      <div className="flex flex-col m-4">
        <Heading4> {"Community"->React.string} </Heading4>
        <Hyperlink href="#" openInNewTab=true> {"Discord"->React.string} </Hyperlink>
        <Hyperlink href="#" openInNewTab=true>
          {"A.P. Morgan Sailing Club"->React.string}
        </Hyperlink>
        <Hyperlink href="#" openInNewTab=true> {"Upcoming Events"->React.string} </Hyperlink>
      </div>
      <div className="flex flex-col m-4">
        <Heading4> {"About"->React.string} </Heading4>
        <Hyperlink href="#" openInNewTab=true> {"Careers"->React.string} </Hyperlink>
        <Hyperlink href="#" openInNewTab=true> {"Press & Brand"->React.string} </Hyperlink>
        <Hyperlink href="#" openInNewTab=true> {"Terms of Service"->React.string} </Hyperlink>
      </div>
      <div className="flex flex-col m-4">
        <p> {"Socials"->React.string} </p>
      </div>
    </div>
    <div className="flex flex-row justify-between md:min-w-full">
      <div className="flex flex-row">
        <Hyperlink href="#" openInNewTab=true> {"Press Kit"->React.string} </Hyperlink>
        <Hyperlink href="#" openInNewTab=true> {"Licenses"->React.string} </Hyperlink>
        <Hyperlink href="#" openInNewTab=true> {"Imprint"->React.string} </Hyperlink>
        <Hyperlink href="#" openInNewTab=true> {"Preferences"->React.string} </Hyperlink>
      </div>
      <p className="m-2">
        {`©${Js.Date.make()
          ->Js.Date.getFullYear
          ->Belt.Float.toString} Global Shipping Foundation`->React.string}
      </p>
    </div>
  </section>
}
