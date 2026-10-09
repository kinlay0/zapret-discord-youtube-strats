# WsProxy

> [!CAUTION] 
>сайты, которые сами стоят на Cloudflare, через Worker идут через публичный NAT64 шлюз и могут открываться через раз (chatgpt.com, может не открыться вообще). если нужны такие сайты - используйте [Deno Worker](#deno-worker), у него такого ограничения нет

данный прокси был основан на идее tg-ws-proxy, только расширенный под определенные домены. идея была реализована на нервотрепном Gemini.

прокси через Cloudflare Worker или Deno для сайтов, которые провайдер блокирует по IP (instagram, facebook, messenger, protonvpn и т.д.), где zapret их не обходит, т.к. до сервера не доходят даже пакеты.

в кратце, это маленький прокси только для выбранных сайтов, где трафик к ним идет через ваш Worker (или Deno) по WebSocket.

через прокси идут только домены из `lists\list-proxy.txt`, все остальное через zapret.

<a id="cloudflare-worker"></a>
<details>
<summary><img src="https://cdn.simpleicons.org/cloudflare" width="16" height="16" alt=""> <b>Cloudflare Worker</b></summary>

### 1. создание

1. заходим на [dash.cloudflare.com](https://dash.cloudflare.com/) - ищем слева `Compute`, тыкаем, находим `Workers & Pages`
    * аккаунта нет? регистрируемся, без этого Worker не создать
2. сверху справа `Create application` -> `Start with Hello World!` -> `Deploy`
3. сверху справа `Edit code`, удаляем весь код и вставляем код [снизу](#worker) -> `Deploy`
4. на странице вашего Worker'а открываем `Settings` (сверху) -> `Variables and Secrets` -> `Add variable`
    1. Environment оставляем на `Production`
    2. в `Key` пишем что хотим, но можно и `KEY` (капсом)
    3. в `Value` пишем свой ключ - любая длинная строка, и обязательно ставим галочку на `Secret`
    4. `Add variable and deploy`
    5. копируем `Secret` и заходим обратно в `Edit code` и заменяем заглушку ключа на ваш собственный.
5. копируем домен Worker'а вида `random-name.username.workers.dev`

### 2. настройка

1. открываем `utils\ws-proxy-settings.txt` и в секции `[cloudflare]` вписываем свои данные (`key` - то, что писали в `Value`):
```
[cloudflare]
url=wss://random-name.username.workers.dev/
key=ваш ключ
```
обязательно учитываем `wss://`!

2. домен Worker'а добавляем в `lists\list-exclude-user.txt`, чтобы стратегии zapret не ломали соединение до cloudflare
    - если Worker без zapret не открывается, тогда наоборот добавляем его в `lists\list-general-user.txt`
3. нужные домены пишем в `lists\list-proxy.txt`.

</details>

<a id="deno-worker"></a>
<details>
<summary><img src="https://cdn.simpleicons.org/deno/000000/ffffff" width="16" height="16" alt=""> <b>Deno Worker</b></summary>

### UPD: cloudflare купил deno и он проработает 6 месяцев https://blog.cloudflare.com/deno-joins-cloudflare/, ладно

альтернатива Cloudflare, клиент тот же, протокол тот же. плюс - сайты на Cloudflare (dash.cloudflare.com и т.д.) открываются

1. заходим на [console.deno.com](https://console.deno.com/) и создаем новое приложение (`New Playground`)
2. удаляем шаблонный код, вставляем код [снизу](#deno) и деплоим
3. в `Settings` (слева) приложения находим `Environment Variables` - выбираем в `Variable Type` - `Secret` и добавляем `KEY` со своим ключом
4. копируем адрес приложения вида `app-name.username.deno.net`
5. в `utils\ws-proxy-settings.txt` в секции `[deno]` вписываем:
```
[deno]
url=wss://app-name.username.deno.net/
key=ваш ключ
```

6. домен Deno добавляем в `lists\list-exclude-user.txt` (или в `list-general-user.txt`, если без zapret не открывается, но у deno нет ограничений в РФ, так что добавляйте в `list-exclude.txt`)
7. нужные домены пишем в `lists\list-proxy.txt`
8. `service.bat` -> `8. WS Proxy` -> `2. Deno`

</details>

### включение

1. запускаем `service.bat` -> `8. WS Proxy` -> выбираем `1. Cloudflare` или `2. Deno`
2. запускаем любую стратегию `general*.bat` вручную или через `1. Install Service`, прокси стартует сам в свернутом окне `zapret: ws-proxy`
или же откройте папку `utils` и запустите `ws-proxy-debug.bat`

выключить: `service.bat` -> `8. WS Proxy` -> `3. Disable`, либо `2. Remove Services`

### проверка
вводим в PowerShell:

```powershell
curl.exe -I -x http://127.0.0.1:1080 https://www.instagram.com/
```
должно быть `200 Connection Established` и после него ответ instagram.

- если хотите узнать с какого айпи идет Worker, то добавьте `ipinfo.io` в `list-proxy.txt`, ждем пару секунд и вводим в PowerShell
```powershell
curl.exe -x http://127.0.0.1:1080 https://ipinfo.io/json
```

если что-то не работает, то запускаем `utils\ws-proxy-debug.bat` (поставьте `verbose=1` в `ws-proxy-settings.txt`), там видно каждое соединение (`PRX` - через прокси) и ошибки.

| Ошибка                           | Что делать                                                                                         |
| -------------------------------- | -------------------------------------------------------------------------------------------------- |
| `403 Forbidden`                  | ключ в `ws-proxy-settings.txt` не совпадает с `Value` переменной `KEY` в Worker'е                          |
| `502` / `Connect failed`         | сайт стоит на Cloudflare или недоступен, уберите домен из `list-proxy.txt`                        |
| `TLS ...`                        | стратегия zapret ломает соединение до Worker'а  добавить домен Worker'а в `list-exclude-user.txt` |
| `TCP connect failed` / `DNS ...` | Worker недоступен у вашего провайдера, нужно добавить домен Worker'а в `list-general-user.txt`          |
| в окне пусто, сайт не грузится   | браузер не использует PAC, перезапустите его                                                      |

### ограничения

- только TCP
- бесплатный план Workers - 100 000 запросов в сутки
- у Deno свои лимиты бесплатного тарифа (смотрите в панели)
- Meta иногда просит капчу

# worker

если в адрес Worker'а дописать `?k=ваш ключ&test=example.com` и открыть в браузере, то Worker проверит прямое подключение и все NAT64 шлюзы и покажет, что из них отвечает.

```js
import { connect } from "cloudflare:sockets";

const KEY = "ваш secret (удалите меня и вставьте ваш ключ)";
const NAT64 = "2a01:4f9:c010:3f02:64::,2a00:1098:2b::,2a01:4f8:c2c:123f:64::,2602:fc59:b0:64::,2001:67c:2960:6464::";
const TIMEOUT = 4000;

function toBytes(data) {
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  if (typeof data === "string") return new TextEncoder().encode(data);
  if (data && typeof data.arrayBuffer === "function") return data.arrayBuffer().then((ab) => new Uint8Array(ab));
  return new Uint8Array();
}

async function resolve4(host) {
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) return host;
  const r = await fetch("https://cloudflare-dns.com/dns-query?name=" + encodeURIComponent(host) + "&type=A", {
    headers: { accept: "application/dns-json" },
  });
  const j = await r.json();
  const a = (j.Answer || []).find((x) => x.type === 1);
  if (!a) throw new Error("no A record");
  return a.data;
}

function toNat64(prefix, ip) {
  const p = ip.split(".").map(Number);
  const h = (a, b) => ((a << 8) | b).toString(16);
  return "[" + prefix + h(p[0], p[1]) + ":" + h(p[2], p[3]) + "]";
}

async function probe(hostname, sni) {
  const t0 = Date.now();
  let s;
  try {
    s = connect({ hostname: hostname, port: 80 });
    const w = s.writable.getWriter();
    const r = s.readable.getReader();
    await w.write(new TextEncoder().encode("HEAD / HTTP/1.1\r\nHost: " + sni + "\r\nConnection: close\r\n\r\n"));
    const res = await Promise.race([
      r.read(),
      new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), 5000)),
    ]);
    const line = res.done ? "closed without data" : new TextDecoder().decode(res.value).split("\r\n")[0];
    return { target: hostname, ms: Date.now() - t0, result: line };
  } catch (e) {
    return { target: hostname, ms: Date.now() - t0, error: String(e) };
  } finally {
    try { s && s.close(); } catch (e) {}
  }
}

async function diagnose(host, prefixes) {
  const out = [];
  out.push(await probe(host, host));
  let ip;
  try { ip = await resolve4(host); } catch (e) { out.push({ resolve: String(e) }); return out; }
  out.push({ ipv4: ip });
  for (const p of prefixes) {
    const v6 = toNat64(p, ip);
    out.push(await probe(v6, host));
    out.push(await probe(v6.slice(1, -1), host));
  }
  return out;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const key = (env && env.KEY) || KEY;
    const authed = key && !key.startsWith("CHANGE-ME") && url.searchParams.get("k") === key;
    if ((request.headers.get("Upgrade") || "").toLowerCase() !== "websocket") {
      if (authed && url.searchParams.get("test")) {
        const list = String((env && env.NAT64 !== undefined) ? env.NAT64 : NAT64).split(",").map((x) => x.trim()).filter(Boolean);
        const report = await diagnose(url.searchParams.get("test").toLowerCase(), list);
        return new Response(JSON.stringify(report, null, 2), { headers: { "content-type": "application/json" } });
      }
      return new Response("Not found", { status: 404 });
    }
    if (!authed) {
      return new Response("Forbidden", { status: 403 });
    }
    const host = (url.searchParams.get("h") || "").toLowerCase();
    const port = parseInt(url.searchParams.get("p") || "443", 10);
    if (!/^[a-z0-9.\-:]{1,253}$/.test(host) || !(port > 0 && port < 65536) || port === 25) {
      return new Response("Bad Request", { status: 400 });
    }
    const prefixes = String((env && env.NAT64 !== undefined) ? env.NAT64 : NAT64)
      .split(",").map((s) => s.trim()).filter(Boolean);

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();

    const pending = [];
    const targets = [host];
    let ip = null;
    let attempt = 0;
    let gotData = false;
    let closed = false;
    let conn = null;
    let timer = null;
    let wq = Promise.resolve();

    const finish = () => {
      if (closed) return;
      closed = true;
      clearTimeout(timer);
      pending.length = 0;
      try { server.close(1000, "done"); } catch (e) {}
      if (conn) {
        conn.dead = true;
        conn.kill();
        try { conn.writer && conn.writer.releaseLock(); } catch (e) {}
        try { conn.s.close(); } catch (e) {}
      }
    };

    const send = (bytes) => {
      const c = conn;
      wq = wq.then(() => {
        if (!c || c.dead || !c.writer) return;
        return Promise.race([c.writer.write(bytes), c.deadP]);
      }).catch(() => {});
    };

    const arm = (c) => {
      clearTimeout(timer);
      timer = setTimeout(() => {
        if (!gotData && conn === c) {
          console.log("timeout", c.target);
          fail(c);
        }
      }, TIMEOUT);
    };

    const fail = (c) => {
      if (c.dead || closed || conn !== c) return;
      c.dead = true;
      c.kill();
      clearTimeout(timer);
      try { c.s.close(); } catch (e) {}
      if (!prefixes.length) return finish();
      (async () => {
        attempt++;
        if (!ip) {
          ip = await resolve4(host);
          for (const p of prefixes) targets.push(toNat64(p, ip));
        }
        if (attempt >= targets.length) throw new Error("all targets failed");
        if (!closed) open(targets[attempt]);
      })().catch((e) => {
        console.log("giveup", host, String(e));
        finish();
      });
    };

    const pump = async (c) => {
      const reader = c.s.readable.getReader();
      try {
        while (true) {
          const { value, done } = await Promise.race([reader.read(), c.deadP.then(() => ({ done: true }))]);
          if (done) break;
          if (value && value.byteLength) {
            if (!gotData) console.log("ok", host, c.target);
            gotData = true;
            clearTimeout(timer);
            pending.length = 0;
            server.send(value);
          }
        }
      } catch (e) {
        console.log("fail", c.target, String(e));
      }
      try { reader.releaseLock(); } catch (e) {}
      if (gotData || closed) {
        if (conn === c) finish();
        return;
      }
      fail(c);
    };

    const open = (target) => {
      const c = { target: target, dead: false };
      c.deadP = new Promise((r) => { c.kill = r; });
      try {
        c.s = connect({ hostname: target, port: port });
        c.writer = c.s.writable.getWriter();
      } catch (e) {
        c.s = { close() {}, readable: new ReadableStream({ start(ctl) { ctl.error(e); } }) };
      }
      conn = c;
      pump(c);
      if (pending.length) arm(c);
      for (const b of pending) send(b);
    };

    open(host);

    server.addEventListener("message", async (event) => {
      const bytes = await toBytes(event.data);
      if (!gotData) {
        pending.push(bytes);
        if (pending.length === 1) arm(conn);
      }
      send(bytes);
    });

    server.addEventListener("close", finish);
    server.addEventListener("error", finish);

    return new Response(null, { status: 101, webSocket: client });
  },
};
```

# deno

```js
const KEY = "ваш secret (удалите меня и вставьте ваш ключ)";

function toBytes(data) {
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  if (typeof data === "string") return new TextEncoder().encode(data);
  if (data && typeof data.arrayBuffer === "function") return data.arrayBuffer().then((ab) => new Uint8Array(ab));
  return new Uint8Array();
}

Deno.serve(async (req) => {
  if ((req.headers.get("upgrade") || "").toLowerCase() !== "websocket") {
    return new Response("Not found", { status: 404 });
  }
  const url = new URL(req.url);
  const key = Deno.env.get("KEY") || KEY;
  if (!key || key.startsWith("CHANGE-ME") || url.searchParams.get("k") !== key) {
    return new Response("Forbidden", { status: 403 });
  }
  const host = (url.searchParams.get("h") || "").toLowerCase();
  const port = parseInt(url.searchParams.get("p") || "443", 10);
  if (!/^[a-z0-9.\-:]{1,253}$/.test(host) || !(port > 0 && port < 65536) || port === 25) {
    return new Response("Bad Request", { status: 400 });
  }

  let conn;
  try {
    conn = await Deno.connect({ hostname: host, port: port });
  } catch (e) {
    console.log("fail", host, String(e));
    return new Response("Bad Gateway", { status: 502 });
  }

  const { socket, response } = Deno.upgradeWebSocket(req);
  socket.binaryType = "arraybuffer";
  const writer = conn.writable.getWriter();
  let closed = false;
  let chain = Promise.resolve();

  const finish = () => {
    if (closed) return;
    closed = true;
    try { writer.releaseLock(); } catch (e) {}
    try { conn.close(); } catch (e) {}
    try { socket.close(1000, "done"); } catch (e) {}
  };

  socket.onopen = async () => {
    try {
      for await (const chunk of conn.readable) {
        if (closed) break;
        socket.send(chunk);
      }
    } catch (e) {}
    finish();
  };

  socket.onmessage = (event) => {
    chain = chain.then(async () => {
      if (closed) return;
      await writer.write(await toBytes(event.data));
    }).catch(finish);
  };

  socket.onclose = finish;
  socket.onerror = finish;

  return response;
});
```