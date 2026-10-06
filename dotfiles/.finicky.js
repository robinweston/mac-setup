// Finicky configuration
// https://github.com/johnste/finicky

export default {
  defaultBrowser: {
    name: "Brave Browser",
    profile: "Work",
  },
  handlers: [
    {
      match: (url) => url.hostname === "propertyguru.com.sg" || url.hostname.endsWith(".propertyguru.com.sg"),
      browser: {
        name: "Brave Browser",
        profile: "Personal",
      },
    },
  ],
};
