import Head from "next/head";

const HtmlHeader = ({ page, children }) => (
  <>
    <Head>
      <title>Envio | {page}</title>
      {/* todo NB need to delete this line when we go out of stealth */}
      <meta name="robots" content="noindex" />
      <link rel="shortcut icon" href="/favicons/favicon.ico" />
      <meta property="og:title" content={`${page}`} key="title" />
      <meta property="og:image" content="#todo" />
      <meta name="viewport" content="width=device-width, initial-scale=1.0" />
      <script
        async
        src="https://www.googletagmanager.com/gtag/js?id=TODO"
      ></script>
      <script
        dangerouslySetInnerHTML={{
          __html: `
            window.dataLayer = window.dataLayer || [];
            function gtag(){dataLayer.push(arguments);}
            gtag('js', new Date());
            gtag('config', 'TODO');
        `,
        }}
      />
      {children}
    </Head>
  </>
);

export default HtmlHeader;
