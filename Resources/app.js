/**
 * RemoteShutter 共享前端脚本。
 *
 * 主页控制台与独立视图页（/cam/back、/cam/front、/cam/mirror）共用这里的能力，
 * 避免同一套交互逻辑在三处各写一遍、改一处漏两处。
 *
 * 设计约定：本文件只提供「无页面假设」的通用能力；每个画面特有的 transform
 * 组合（镜像/旋转的先后顺序不同）由调用方通过 redraw 回调决定。
 */
(function (global) {
    'use strict';

    /**
     * object-fit:contain 下，图片真实内容在元素盒子内的矩形（剔除黑边留白）。
     * 点击/滑动坐标必须基于这个矩形换算，否则旋转或有黑边时会点偏。
     */
    function contentRect(img) {
        var r = img.getBoundingClientRect();
        var iw = img.naturalWidth || 1;
        var ih = img.naturalHeight || 1;
        var sr = r.width / (r.height || 1);
        var ir = iw / ih;
        var cw, ch, ox, oy;
        if (sr > ir) {
            ch = r.height; cw = ch * ir; ox = (r.width - cw) / 2; oy = 0;
        } else {
            cw = r.width; ch = cw / ir; oy = (r.height - ch) / 2; ox = 0;
        }
        return { x: r.left + ox, y: r.top + oy, w: cw, h: ch };
    }

    function clampZoom(v) { return Math.max(1, Math.min(5, v)); }

    /**
     * 缩放/平移状态机：只维护 zoom / pan 数值，变化时回调 redraw。
     * 具体 transform 字符串由调用方拼装（各页面镜像/旋转需求不同）。
     */
    function createZoomPan(redraw) {
        var z = 1;
        var pan = { x: 0, y: 0 };
        return {
            get zoom() { return z; },
            get pan() { return pan; },
            zoomBy: function (d) {
                z = clampZoom(z + d);
                if (z === 1) pan = { x: 0, y: 0 };   // 回到原始大小时归位，避免残留偏移
                redraw();
            },
            panBy: function (dx, dy) {
                pan = { x: pan.x + dx, y: pan.y + dy };
                redraw();
            },
            reset: function () { z = 1; pan = { x: 0, y: 0 }; redraw(); }
        };
    }

    /** 绑定一组缩放按钮；ids 里某项不存在就跳过（各页面按钮不一定齐全）。 */
    function bindZoomButtons(zp, ids) {
        ids = ids || {};
        var map = [['in', 0.25], ['out', -0.25]];
        map.forEach(function (m) {
            var el = ids[m[0]] && document.getElementById(ids[m[0]]);
            if (el) el.onclick = function () { zp.zoomBy(m[1]); };
        });
        var reset = ids.reset && document.getElementById(ids.reset);
        if (reset) reset.onclick = function () { zp.reset(); };
    }

    /** 绑定全屏按钮；target 为要全屏的元素，缺省用整个文档。 */
    function bindFullscreen(id, target) {
        var el = document.getElementById(id);
        if (!el) return;
        var t = target || document.documentElement;
        el.onclick = function () {
            var fsEl = document.fullscreenElement || document.webkitFullscreenElement;
            if (!fsEl) {
                var req = t.requestFullscreen || t.webkitRequestFullscreen;
                if (req) req.call(t);
            } else {
                var exit = document.exitFullscreen || document.webkitExitFullscreen;
                if (exit) exit.call(document);
            }
        };
    }

    /**
     * 画面手势绑定：
     * - 未放大：短按 → onTap；长按且移动超过阈值 → onSwipe（起点→终点）
     * - 已放大：按住拖动 → 平移画面，且不触发点击/滑动
     * 另外拦截浏览器原生图片拖拽（否则按住拖动会拖出一张图片，手势失效）。
     */
    function bindGestures(img, zp, handlers) {
        handlers = handlers || {};
        var dx = 0, dy = 0, dt = 0, cx = 0, cy = 0, moved = false;

        img.addEventListener('dragstart', function (e) { e.preventDefault(); return false; });

        img.addEventListener('pointerdown', function (e) {
            e.preventDefault();                       // 阻止原生拖拽/选中
            var rc = contentRect(img);
            dx = (e.clientX - rc.x) / rc.w;
            dy = (e.clientY - rc.y) / rc.h;
            cx = e.clientX; cy = e.clientY; dt = Date.now(); moved = false;
            if (img.setPointerCapture) { try { img.setPointerCapture(e.pointerId); } catch (_) { } }
        });

        img.addEventListener('pointermove', function (e) {
            if (zp.zoom > 1 && (e.buttons & 1)) {
                var ex = e.clientX - cx, ey = e.clientY - cy;
                if (Math.abs(ex) > 3 || Math.abs(ey) > 3) moved = true;
                zp.panBy(ex, ey);
                cx = e.clientX; cy = e.clientY;
            }
        });

        img.addEventListener('pointerup', function (e) {
            if (moved) return;                        // 放大态的拖动视为平移
            var rc = contentRect(img);
            var nx = (e.clientX - rc.x) / rc.w;
            var ny = (e.clientY - rc.y) / rc.h;
            var dur = Date.now() - dt;
            if (dur > 250 && (Math.abs(nx - dx) > 0.02 || Math.abs(ny - dy) > 0.02)) {
                if (handlers.onSwipe) handlers.onSwipe(dx, dy, nx, ny);
            } else {
                if (handlers.onTap) handlers.onTap(nx, ny);
            }
        });
    }

    /** 触发一次 /tap（tap 或 swipe）。坐标为画面归一化 0~1。 */
    function sendTap(nx, ny, action, nx2, ny2) {
        var q = '/tap?nx=' + nx.toFixed(4) + '&ny=' + ny.toFixed(4) + '&action=' + (action || 'tap');
        if (nx2 != null && ny2 != null) {
            q += '&nx2=' + nx2.toFixed(4) + '&ny2=' + ny2.toFixed(4);
        }
        return post(q);
    }

    function post(path) { return fetch(path, { method: 'POST' }).catch(function () { }); }

    /** 带 data-key 的按钮 → POST /key?action=...（返回键/主页/后台/音量/锁屏/截图等） */
    function bindKeyButtons(selector) {
        document.querySelectorAll(selector).forEach(function (b) {
            b.addEventListener('click', function () {
                post('/key?action=' + b.getAttribute('data-key'));
            });
        });
    }

    /**
     * 屏幕镜像流：请求后端开启 → 加载 MJPEG。
     * 连接中断时轮询 /screenmirror/status，配合后端看门狗自动恢复后重新加载，无需用户手动刷新。
     * onStatus(text) 用于把「重连中/已断开」提示显示到页面上。
     */
    function bindMirrorStream(img, opts) {
        opts = opts || {};
        var onStatus = opts.onStatus || function () { };
        var running = false;
        var retries = 0;
        var reconnecting = false;
        var wSel = 0, qSel = 0;

        function streamUrl() {
            var p = [];
            if (wSel) p.push('w=' + wSel);
            if (qSel) p.push('q=' + qSel);
            p.push('t=' + Date.now());
            return opts.stream + '?' + p.join('&');
        }

        function load() {
            img.alt = '';
            img.src = streamUrl();
        }

        function reconnect() {
            if (reconnecting || !running) return;
            reconnecting = true;
            onStatus('🔄 屏幕镜像断开，重连中…');
            (function check() {
                if (!running) { reconnecting = false; return; }
                fetch(opts.status).then(function (x) { return x.json(); }).then(function (s) {
                    if (s.running) { reconnecting = false; load(); }
                    else if (retries < 200) { retries++; setTimeout(check, 800); }
                    else { reconnecting = false; onStatus('⚠️ 屏幕镜像已断开，请重新点击「🖥️ 屏幕镜像」'); }
                }).catch(function () {
                    if (retries < 200) { retries++; setTimeout(check, 800); }
                    else { reconnecting = false; }
                });
            })();
        }

        return {
            /** 开启镜像流；返回 Promise<Boolean> 表示是否启动成功，便于调用方更新按钮状态 */
            start: function () {
                // 带上清晰度参数，后端据此决定抓屏分辨率与 JPEG 质量。
                // 注意 opts.start 形如 "/screenmirror?start=1"，已有查询串，只能追加 "&"。
                var q = [];
                if (wSel) q.push('w=' + wSel);
                if (qSel) q.push('q=' + qSel);
                var url = opts.start + (q.length ? ('&' + q.join('&')) : '');
                return fetch(url, { method: 'POST' })
                    .then(function (r) { return r.json(); })
                    .then(function (j) {
                        if (!j.ok) { onStatus('屏幕镜像启动失败'); return false; }
                        running = true;
                        img.onerror = reconnect;
                        load();
                        return true;
                    })
                    .catch(function () { onStatus('屏幕镜像启动失败'); return false; });
            },
            /** 切换抓屏清晰度：w=抓屏宽度上限，q=JPEG 质量(30~90)；已运行时立即重载 */
            setQuality: function (w, q) {
                wSel = w || 0;
                qSel = q || 0;
                if (running) {
                    onStatus('🔧 清晰度已切换：宽 ' + (wSel || '默认') + ' / 质量 ' + (qSel || '默认') + '，正在重载画面…');
                    load();
                    // 重载后回查服务端实际生效的分辨率并显示，便于确认切换真的生效
                    setTimeout(function () {
                        fetch(opts.status).then(function (x) { return x.json(); }).then(function (s) {
                            if (s && s.running) {
                                onStatus('🔧 当前清晰度：' + (s.w || '?') + '×' + (s.h || '?') +
                                    ' / 质量 ' + (qSel || '默认'));
                            }
                        }).catch(function () { });
                    }, 1500);
                } else {
                    onStatus('🔧 清晰度已设为 宽 ' + (wSel || '默认') + ' / 质量 ' + (qSel || '默认') + '，下次开启屏幕镜像时生效');
                }
            },
            stop: function () {
                running = false;
                img.onerror = null;
                img.src = '';
                fetch(opts.stop, { method: 'POST' }).catch(function () { });
            }
        };
    }

    /**
     * 音频流播放：WebSocket 收 16bit 小端 PCM → 入队 → WebAudio 播放。
     * 麦克风（/audio）与系统媒体声（/audio/system）共用这一套实现，只是路径与按钮文案不同。
     * 音质：通过采样率控制（8k/16k/48k），采样率越低网络带宽越小，越适合弱网。
     * 返回的 setRate(rate) 会通知后端切换采集采样率并自动重连，无需刷新页面。
     */
    function bindAudioStream(btnId, path, onStatus, labels, opts) {
        opts = opts || {};
        var btn = document.getElementById(btnId);
        onStatus = onStatus || function () { };
        labels = labels || {};
        var idleText = labels.idle || '🔈 镜像声音';
        var liveText = labels.live || '🔇 关闭镜像声音';
        var qualityPath = opts.qualityPath || (path + '/quality');
        var rate = opts.rate || 48000;

        if (!btn) return { stop: function () { }, isOn: function () { return false; }, setRate: function () { } };

        var on = false, ctx = null, node = null, ws = null, q = [];
        var lastSample = 0;     // 轻微欠载时保持上一采样（下面改为静音填补，这里仅留作兜底）
        var primed = false;     // 预缓冲门控：队列足够才出声，吸收网络抖动
        var primeBytes = 8192;

        function disable() {
            try { if (ws) ws.close(); } catch (e) { }
            try { if (node) node.disconnect(); } catch (e) { }
            try { if (ctx) ctx.suspend(); } catch (e) { }
            on = false; q = []; primed = false; lastSample = 0;
            btn.textContent = idleText;
            btn.classList.remove('on');
            onStatus(labels.close || '声音已关闭');
        }

        function enable() {
            try {
                var reqRate = rate;
                // 尽量按所选采样率建 AudioContext；浏览器不支持时回退默认（后端会把采集率重采样到实际播放率）
                try {
                    ctx = new (global.AudioContext || global.webkitAudioContext)({ sampleRate: reqRate });
                } catch (e) {
                    ctx = new (global.AudioContext || global.webkitAudioContext)();
                }
                var deliver = ctx.sampleRate;   // 实际播放率；WebSocket 据此下发，后端重采样到该率
                primeBytes = Math.max(4096, Math.floor(deliver / 1000 * 120 * 2)); // 预缓冲约 120ms 抗抖
                node = ctx.createScriptProcessor(4096, 1, 1);
                node.onaudioprocess = function (e) {
                    var out = e.outputBuffer.getChannelData(0);
                    // 预缓冲：队列不足时先静音，避免网络抖动造成的开局爆音 / 断流
                    if (!primed) {
                        if (q.length >= primeBytes) primed = true;
                        else { for (var i = 0; i < out.length; i++) out[i] = 0; return; }
                    }
                    for (var i = 0; i < out.length; i++) {
                        if (q.length >= 2) {
                            var lo = q.shift(), hi = q.shift();
                            var s = (hi << 8) | lo;
                            if (s > 32767) s -= 65536;
                            lastSample = s / 32768;
                            out[i] = lastSample;
                        } else {
                            out[i] = 0;   // 轻微欠载：静音填补，比维持上一采样更不易产生嗡嗡声
                        }
                    }
                };
                node.connect(ctx.destination);
                ctx.resume();
                var proto = location.protocol === 'https:' ? 'wss://' : 'ws://';
                // 公网观看时页面在 /d/<设备ID>/ 下：WS 也带设备前缀与观看密钥，
                // 否则绝对路径 /audio 只能靠 Cookie 路由，中继容易 403 → 按钮无反应、没声音。
                // 局域网直连（路径为 /）时保持原样，不影响本地使用。
                var wsPath = path;
                var dm = location.pathname.match(/^\/d\/([A-Za-z0-9_-]{1,64})\//);
                if (dm) wsPath = '/d/' + dm[1] + path;
                var viewK = new URLSearchParams(location.search).get('k');
                var wsQuery = 'rate=' + deliver + (viewK ? '&k=' + encodeURIComponent(viewK) : '');
                ws = new WebSocket(proto + location.host + wsPath + '?' + wsQuery);
                ws.binaryType = 'arraybuffer';
                ws.onopen = function () {
                    on = true; primed = false;
                    btn.textContent = liveText;
                    btn.classList.add('on');
                    onStatus((labels.open || '声音已开启') + '（' + deliver + 'Hz）');
                };
                ws.onmessage = function (ev) {
                    var arr = new Uint8Array(ev.data);
                    for (var i = 0; i < arr.length; i++) q.push(arr[i]);
                };
                ws.onerror = function () { onStatus(labels.error || '声音连接错误，请重试'); };
                ws.onclose = function () {
                    if (on) {
                        on = false; q = []; primed = false;
                        btn.textContent = idleText;
                        btn.classList.remove('on');
                        onStatus(labels.drop || '声音已断开');
                    }
                };
            } catch (e) {
                onStatus((labels.open || '声音开启') + '失败：' + e);
            }
        }

        /** 切换音质（采样率）：通知后端改采集率，若正在播放则自动重连以应用新率。 */
        function setRate(r) {
            rate = r || 48000;
            // 通知后端切换采集采样率（重采样到下发率，直接决定网络带宽）
            fetch(qualityPath + '?rate=' + rate, { method: 'GET' }).catch(function () { });
            if (on) { disable(); enable(); }
            else onStatus('🔧 音质已设为 ' + (rate / 1000) + 'kHz（下次开启声音生效）');
        }

        btn.addEventListener('click', function () { if (on) disable(); else enable(); });
        return { stop: disable, isOn: function () { return on; }, setRate: setRate };
    }

    /** 屏幕镜像的系统媒体声（内部复用 bindAudioStream） */
    function bindSystemAudio(btnId, onStatus) {
        return bindAudioStream(btnId, '/audio/system', onStatus, {
            idle: '🔈 镜像声音', live: '🔇 关闭镜像声音',
            open: '🔈 镜像声音已开启', close: '镜像声音已关闭',
            error: '镜像声音连接错误，请重试', drop: '镜像声音已断开'
        }, { rate: 48000, qualityPath: '/audio/system/quality' });
    }

    /** 麦克风现场声（内部复用 bindAudioStream） */
    function bindMicAudio(btnId, onStatus) {
        return bindAudioStream(btnId, '/audio', onStatus, {
            idle: '🔊 开启声音', live: '🔇 关闭声音',
            open: '🔊 现场声音已开启', close: '声音已关闭',
            error: '声音连接错误，请重试', drop: '声音已断开'
        }, { rate: 48000, qualityPath: '/audio/quality' });
    }

    /**
     * 系统媒体音频（旧版内联实现，保留以兼容仍在使用的页面标记 data-sysaudio）。
     * 新代码请直接用 bindSystemAudio。
     */
    global.RS = {
        contentRect: contentRect,
        createZoomPan: createZoomPan,
        bindZoomButtons: bindZoomButtons,
        bindFullscreen: bindFullscreen,
        bindGestures: bindGestures,
        bindKeyButtons: bindKeyButtons,
        bindMirrorStream: bindMirrorStream,
        bindAudioStream: bindAudioStream,
        bindSystemAudio: bindSystemAudio,
        bindMicAudio: bindMicAudio,
        sendTap: sendTap,
        post: post
    };
})(window);
