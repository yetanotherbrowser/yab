let lastNotification;
chrome.runtime.onMessage.addListener((message,sender,reply)=>{
  if(message.kind==='sender'){reply(sender);return;}
  if(message.kind==='resource-sender'){
    chrome.tabs.sendMessage(sender.tab.id, {kind:'resource-reply'},
      {frameId:sender.frameId,documentId:sender.documentId})
      .then(reverse=>reply({sender,reverse}),error=>reply({error:String(error)}));
    return true;
  }
  if(message.kind==='notification'){lastNotification=message.nonce;return;}
  if(message.kind==='last-notification'){reply(lastNotification);return;}
  if(message.kind==='storage-access'){
    chrome.storage.local.setAccessLevel({accessLevel:message.allow?'TRUSTED_AND_UNTRUSTED_CONTEXTS':'TRUSTED_CONTEXTS'}).then(()=>reply(true));return true;
  }
  if(message.kind!=='acceptance')return;
  (async()=>{
    await chrome.storage.local.set({witness:message.nonce});
    const reverse=await chrome.tabs.sendMessage(sender.tab.id,{kind:'reverse',nonce:message.nonce},{frameId:sender.frameId,documentId:sender.documentId});
    const scripted=await chrome.scripting.executeScript({target:{tabId:sender.tab.id,frameIds:[sender.frameId]},func:()=>{document.documentElement.dataset.bridgeScript='yes';return 'executed-in-webkit'}});
    await chrome.scripting.insertCSS({target:{tabId:sender.tab.id,frameIds:[sender.frameId]},css:'#bridge-witness { color: rgb(141, 246, 184); }'});
    const queried=await chrome.tabs.get(sender.tab.id);
    return {sender,reverse,scripted,queried};
  })().then(reply,error=>reply({error:String(error)}));
  return true;
});
chrome.runtime.onConnect.addListener(port=>{
  port.onMessage.addListener(message=>port.postMessage({echo:message,document:port.sender.documentId}));
});
