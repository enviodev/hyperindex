import Home from "../src/page-contents/Home.bs.js";
import HtmlHeader from "../src/components/HtmlHeader.js";
import Head from "next/head";

export default function Index(props) {
  return (
    <div>
      <HtmlHeader page="Landing site"></HtmlHeader>
      <Head>
        <meta name="description" content="" />
      </Head>
      <Home {...props} />
    </div>
  );
}
