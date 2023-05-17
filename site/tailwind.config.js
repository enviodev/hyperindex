const primaryColor = "#FF8267";
const secondaryColor = "#FDD700";

// Original colour scheme
// todo: delete once committed to sunrise
// const primaryColor = "#2575FC";
// const secondaryColor = "#A223CF";

// terminal colour schemes - inspired by robby russel
const terminalRed = "#D7625D";
const terminalLightBlue = "#6DA39E";
const terminalDarkBlue = "#72899C";
const terminalGreen = "#AFB26F";
const terminalYellow = "#F1C875";
const terminalBg = "#28292E";

module.exports = {
  content: ["./src/**/*.res"],
  safelist: [
    {
      pattern: /order-(1|2|3|4|5|6|7|9|10|11|12|first|last|none)/,
      variants: ["md"],
    },
  ],
  darkMode: "class",
  theme: {
    extend: {
      keyframes: {
        "curve-fade-in": {
          "0%": { opacity: "0" },
          "20%": { opacity: "0.4" },
          "100%": { opacity: "1" },
        },
      },
      animation: {
        "curve-fade-in": "curve-fade-in 5s",
      },
      screens: {
        nav: "1100px",
      },
      colors: {
        primary: primaryColor,
        secondary: secondaryColor,
        terminalRed: terminalRed,
        terminalLightBlue: terminalLightBlue,
        terminalDarkBlue: terminalDarkBlue,
        terminalGreen: terminalGreen,
        terminalYellow: terminalYellow,
        terminalBg: terminalBg,
      },
      borderColor: {
        DEFAULT: primaryColor,
      },
      width: {
        "1/6": "17%",
        "1/8": "12%",
        "1/10": "10%",
        "1/12": "8%",
        "1/16": "6%",
        "slightly-less-than-half": "45%",
        "30-percent": "30%",
        "40-percent": "40%",
        half: "50%",
        "60-percent": "60%",
        "70-percent": "70%",
        "9/10": "90%",
        "15/10": "150%",
        "price-width": "12rem",
        "code-block": "700px", //todo
        "frame-width": "10rem",
        big: "28rem",
      },
      maxWidth: {
        "mint-width": "40rem",
        xxs: "15rem",
        big: "28rem",
        "50p": "50%",
      },
      margin: {
        "minus-12": "-3.4rem",
        "minus-quarter": "-25%",
        "minus-1": "-0.4rem",
      },
      inset: {
        half: "50%",
      },
      height: {
        "80-percent-screen": "80vh",
        "picture-height": "6rem",
        big: "28rem",
        "70-percent-screen": "70vh",
        "60-percent-screen": "60vh",
        "50-percent-screen": "50vh",
        undersized: "80%",
        oversized: "120%",
        "code-block": "400px",
      },
      boxShadow: {
        "inner-card": "inset 1px 1px 2px 0 rgba(0, 0, 0, 0.3)",
        "outer-card": "2px 2px 2px 0 rgba(0, 0, 0, 0.3)",
      },
      scale: {
        102: "1.02",
      },
      fontSize: {
        xxxxs: ".4rem",
        xxxs: ".5rem",
        xxs: ".6rem",
      },
      maxHeight: {
        "1/4": "25%",
        "1/2": "50%",
        "3/4": "75%",
        "9/10": "90%",
        "40-percent-screen": "40vh",
        "50-percent-screen": "50vh",
        "60-percent-screen": "60vh",
      },
      minWidth: {
        "1/2": "50%",
        "3/4": "75%",
        340: "340px",
        400: "400px",
        500: "500px",
        56: "56px",
        6: "1.5rem",
        md: "768px",
      },
      minHeight: {
        "half-screen": "50vh",
        "eighty-percent-screen": "80vh",
      },
      letterSpacing: {
        "btn-text": "0.2em",
      },
      order: {
        13: "13",
        14: "14",
        15: "15",
        16: "16",
        17: "17",
        18: "18",
      },
    },

    /* We override the default font-families with our own default prefs  */
    fontFamily: {
      sans: [
        "-apple-system",
        "BlinkMacSystemFont",
        "Helvetica Neue",
        "Arial",
        "sans-serif",
      ],
      serif: [
        "Georgia",
        "-apple-system",
        "BlinkMacSystemFont",
        "Helvetica Neue",
        "Arial",
        "sans-serif",
      ],
      mono: [
        "Menlo",
        "Monaco",
        "Consolas",
        "Roboto Mono",
        "SFMono-Regular",
        "Segoe UI",
        "Courier",
        "monospace",
      ],
      "font-name": ["font-name"],
      default: ["menlo", "'Roboto Mono'", "sans-serif"],
    },
  },
  plugins: [],
};
