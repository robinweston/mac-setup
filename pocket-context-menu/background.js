// Helper function to create Pocket URL
function createPocketUrl(url) {
  const encodedUrl = encodeURIComponent(url);
  return `https://getpocket.com/edit?url=${encodedUrl}&url=${encodedUrl}`;
}

// Open and close tab after it loads
async function openAndCloseTab(url) {
  const tab = await chrome.tabs.create({ 
    url: createPocketUrl(url), 
    active: false 
  });

  // Create a promise that resolves when the tab finishes loading
  const tabLoaded = new Promise((resolve) => {
    const listener = (tabId, changeInfo) => {
      if (tabId === tab.id && changeInfo.status === 'complete') {
        chrome.tabs.onUpdated.removeListener(listener);
        resolve();
      }
    };
    chrome.tabs.onUpdated.addListener(listener);
  });

  // Wait for the tab to load, then close it
  await tabLoaded;
  chrome.tabs.remove(tab.id);
}

// Create the context menu item when the extension is installed
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "saveToPocket",
    title: "Save to Pocket",
    contexts: ["link"]
  });
});

// Handle the context menu click
chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === "saveToPocket") {
    openAndCloseTab(info.linkUrl);
  }
});

// Handle the browser action click
chrome.action.onClicked.addListener((tab) => {
  openAndCloseTab(tab.url);
}); 