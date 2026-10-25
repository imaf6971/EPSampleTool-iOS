// Golden vectors generated from functions copied verbatim (de-minified names only)
// from the EP Sample Tool bundle, so the Swift port can be checked byte for byte.
function unpackInPlace(a){let s=0,o=0,_=0,c=1,d=a[o];for(;c<a.length;){const g=(d&1<<_?1:0)<<7,h=a[c]&127,b=g|h;a[s]=b,++_,++c,++s,_>6&&(++c,_=0,o+=8,d=a[o])}return a.subarray(0,s)}
function packToBuffer(a,s){let o=1,_=0;for(let c=0;c<a.length;++c){const d=c%7,g=a[c]>>7;s[_]|=g<<d,s[o++]=a[c]&127,d==6&&c<a.length-1&&(_+=8,o++)}}
function frame(deviceId,requestId,cmd,payload){const c=payload.length>0?payload.length+Math.ceil(payload.length/7):0,d=new Uint8Array(10+c),g=requestId;d[0]=240,d[1]=0,d[2]=32,d[3]=118,d[4]=deviceId,d[5]=64,d[6]=64|32|g>>7&31,d[7]=g&127,d[8]=cmd,d[d.length-1]=247,packToBuffer(payload,d.subarray(9,9+c));return d}
function calculateMaxPayloadLength(a){const o=8+2+1;if(a<=o)return 0;const _=a-1-o;return _-Math.floor(_/8)}
function normalizeFileName(a,s=!1){return s&&(a=a.replace(/^\d{3}\s/,"")),a=a.split(".").slice(0,-1).join(".")||a,a=a.replace(/\//g,""),a=a.trim(),a=a.normalize("NFD").replace(new RegExp("\\p{Diacritic}","gu"),""),a=a.replace(/[^\x20-\x7F]/g,"?"),a=a.replace(/[\\"]/g,""),a.length>16&&(a=a.substring(0,7)+"."+a.substring(a.length-8)),a.toLowerCase()}
function writeStringToView(a,s,o,_=!1){let c=s;for(let d=0;d<o.length;d++)c=s+d,a.setUint8(c,o.charCodeAt(d));return _&&s>0&&(c++,a.setUint8(c,0)),c}
function putInit(fileId,parentId,flags,fileSize,filename,metadata){filename=filename.slice(0,54);const s=11+(filename.length+1),o=new Uint8Array(s),_=new DataView(o.buffer);_.setUint8(0,2),_.setUint8(1,0),_.setUint8(2,flags),_.setUint16(3,fileId),_.setUint16(5,parentId),_.setUint32(7,fileSize),writeStringToView(_,11,filename,!0);let c=new Uint8Array(0);if(metadata!=null){c=new Uint8Array(metadata.length);writeStringToView(new DataView(c.buffer),0,metadata,!0)}return new Uint8Array([...o,...c])}
function setMeta(fileId,metadata){const s=new Uint8Array(4+metadata.length+1),o=new DataView(s.buffer);o.setUint8(0,7),o.setUint8(1,1),o.setUint16(2,fileId),writeStringToView(o,4,metadata,!0);return s}
function getMeta(fileId,page){const o=new Uint8Array(6),_=new DataView(o.buffer);_.setUint8(0,7),_.setUint8(1,2),_.setUint16(2,fileId),_.setUint16(4,page);return o}
function fileInit(maxLen,flags){const s=new Uint8Array(6),o=new DataView(s.buffer);o.setUint8(0,1),o.setUint8(1,flags),o.setUint32(2,maxLen);return s}
function playback(fileId,action,offset,length){const s=new Uint8Array(12),o=new DataView(s.buffer);o.setUint8(0,5),o.setUint8(1,action),o.setUint16(2,fileId),o.setUint32(4,offset),o.setUint32(8,length);return s}

const arr = (u) => Array.from(u);
const rnd = (n, seed) => { let x = seed; return Array.from({ length: n }, () => (x = (x * 1103515245 + 12345) & 0x7fffffff) & 0xff); };

const packCases = [0, 1, 6, 7, 8, 13, 14, 15, 100, 257].map((n, i) => {
  const data = rnd(n, i + 1);
  const packed = new Uint8Array(n > 0 ? n + Math.ceil(n / 7) : 0);
  packToBuffer(data, packed);
  const unpacked = unpackInPlace(new Uint8Array(packed));
  if (arr(unpacked).join() !== data.join()) throw new Error(`JS roundtrip mismatch n=${n}`);
  return { data, packed: arr(packed) };
});

const out = {
  pack: packCases,
  frames: [
    { deviceId: 0, requestId: 0, cmd: 1, payload: [], bytes: arr(frame(0, 0, 1, [])) },
    { deviceId: 3, requestId: 4095, cmd: 5, payload: arr(fileInit(4 * 1024 * 1024, 1)), bytes: arr(frame(3, 4095, 5, fileInit(4 * 1024 * 1024, 1))) },
    { deviceId: 1, requestId: 300, cmd: 5, payload: rnd(20, 99), bytes: arr(frame(1, 300, 5, rnd(20, 99))) },
  ],
  maxPayload: [0, 11, 12, 13, 64, 512, 1024, 4096, 8192].map((c) => ({ chunkSize: c, value: calculateMaxPayloadLength(c - 6) })),
  names: ["Kick 01.wav", "snare.aif", "noext", "a.b.c.wav", "  spaced  .wav", "Crème brûlée.wav", "very long sample name here.wav", 'quo"te\\s.wav', "path/with/slash.wav", "日本語.mp3", "UPPER.WAV"]
    .map((n) => ({ input: n, output: normalizeFileName(n) })),
  requests: {
    putInit: arr(putInit(12, 1000, 5, 93750, "kick 01", JSON.stringify({ channels: 1, samplerate: 46875 }))),
    putInitNoMeta: arr(putInit(999, 2, 5, 1, "x".repeat(60), null)),
    setMeta: arr(setMeta(12, JSON.stringify({ name: "kick" }))),
    getMeta: arr(getMeta(12, 3)),
    fileInit: arr(fileInit(4 * 1024 * 1024, 1)),
    playStart: arr(playback(12, 1, 0, 0)),
    playStop: arr(playback(12, 2, 0, 0)),
  },
};
console.log(JSON.stringify(out, null, 1));
