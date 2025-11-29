// ==UserScript==
// @name         linux.do 清爽模式（强制居中 + 禁止横向滚动 · 全面优化版）
// @namespace    https://linux.do/
// @version      4.0.0
// @description  清爽模式 + 强制页面居中对齐 + 禁止左右滑动；PC/移动端自适应浅/深色；无按钮无快捷键；对 linux.do 进行定制隐藏。
// @match        https://linux.do/*
// @match        https://idcflare.com/*
// @run-at       document-end
// @noframes
// @grant        none
// ==/UserScript==

(function () {
    'use strict';

    const CLEAN_CLASS = 'ld-clean-mode';
    const HIDDEN_ATTR = 'data-ld-clean-hidden';
    const STYLE_ID = 'ld-clean-style';

    const host = location.hostname;
    const isLinuxDo = /(^|\.)linux\.do$/i.test(host);
    const isIdcflare = /(^|\.)idcflare\.com$/i.test(host);

    /* =============================
     * 样式注入
     * ============================= */
    function injectBaseStyle() {
        if (document.getElementById(STYLE_ID)) return;

        const style = document.createElement('style');
        style.id = STYLE_ID;
        style.textContent = `
/* =========================================================
   基础：强制居中 + 禁止横向滚动 + 全局字体优化
========================================================= */

html.${CLEAN_CLASS},
html.${CLEAN_CLASS} body {
    /* 禁止水平滚动条（长内容会被裁切，属预期行为） */
    overflow-x: hidden !important;
}

html.${CLEAN_CLASS} body {
    margin: 0 auto !important;
    width: 100%;
    position: relative;
    -webkit-font-smoothing: antialiased;
    font-family: system-ui, -apple-system, "Segoe UI", "PingFang SC", "Microsoft Yahei", sans-serif;
    text-rendering: optimizeLegibility;
}

/* 主容器居中 + 最大宽度约束（桌面端） */
html.${CLEAN_CLASS} #main-outlet,
html.${CLEAN_CLASS} .wrap {
    margin: 0 auto !important;
    width: 100%;
    max-width: 1180px;
    position: relative;
}

/* 移动端进一步收窄，避免长内容撑开宽度 */
@media (max-width: 768px) {
    html.${CLEAN_CLASS} #main-outlet,
    html.${CLEAN_CLASS} .wrap {
        max-width: 640px !important;
    }
}

/* =========================================================
   PC 端轻量美化，不改配色（由系统主题控制光暗）
========================================================= */

@media (min-width: 769px) {
    html.${CLEAN_CLASS} .topic-list {
        border: 0;
        background: transparent;
    }

    html.${CLEAN_CLASS} .topic-list thead th {
        font-size: 12px;
        border-bottom-width: 1px;
        background: transparent;
        opacity: 0.9;
    }

    html.${CLEAN_CLASS} .topic-list tbody tr {
        transition: background-color 0.12s ease-out;
    }

    html.${CLEAN_CLASS} .topic-list tbody tr:hover {
        background-color: rgba(148, 163, 184, 0.08);
    }

    html.${CLEAN_CLASS} .topic-list .main-link a.title {
        font-size: 15px;
        font-weight: 550;
    }

    html.${CLEAN_CLASS} .topic-body .regular,
    html.${CLEAN_CLASS} .cooked {
        line-height: 1.75;
        font-size: 15.5px;
    }

    html.${CLEAN_CLASS} #footer,
    html.${CLEAN_CLASS} .footer {
        opacity: 0.55;
        font-size: 12px;
    }
}

/* =========================================================
   移动端卡片布局（深浅色跟随系统）
========================================================= */

/* 卡片结构（纯结构，不带具体配色） */
@media (max-width: 768px) {
    html.${CLEAN_CLASS} .topic-list {
        border: 0;
        background: transparent;
    }

    html.${CLEAN_CLASS} .topic-list thead {
        display: none;
    }

    html.${CLEAN_CLASS} .topic-list tbody tr {
        display: block;
        border-radius: 14px;
        margin-bottom: 12px;
        padding: 6px 0;
        border-width: 1px;
        border-style: solid;
        box-shadow: 0 6px 18px rgba(0, 0, 0, 0.12);
    }

    html.${CLEAN_CLASS} .topic-list tbody tr td {
        display: block;
        padding: 6px 12px;
        border: none !important;
    }

    html.${CLEAN_CLASS} .topic-list .main-link a.title {
        font-size: 16px;
        font-weight: 600;
    }

    html.${CLEAN_CLASS} .topic-post {
        border-radius: 16px;
        border-width: 1px;
        border-style: solid;
        padding: 12px 14px;
        margin: 12px 0;
        box-shadow: 0 6px 22px rgba(0, 0, 0, 0.12);
    }
}

/* 浅色系统 */
@media (max-width: 768px) and (prefers-color-scheme: light) {
    html.${CLEAN_CLASS} body {
        background: #f6f7f9;
    }

    html.${CLEAN_CLASS} .d-header {
        background: rgba(255, 255, 255, 0.9);
        border-bottom: 1px solid rgba(0, 0, 0, 0.06);
        backdrop-filter: blur(10px);
    }

    html.${CLEAN_CLASS} .topic-list tbody tr {
        background: #ffffff;
        border-color: rgba(0, 0, 0, 0.06);
    }

    html.${CLEAN_CLASS} .topic-post {
        background: #ffffff;
        border-color: rgba(0, 0, 0, 0.06);
    }
}

/* 深色系统 */
@media (max-width: 768px) and (prefers-color-scheme: dark) {
    html.${CLEAN_CLASS} body {
        background: #020617;
    }

    html.${CLEAN_CLASS} .d-header {
        background: rgba(15, 23, 42, 0.96);
        border-bottom: 1px solid rgba(51, 65, 85, 0.9);
        backdrop-filter: blur(10px);
    }

    html.${CLEAN_CLASS} .topic-list tbody tr {
        background: rgba(15, 23, 42, 0.96);
        border-color: rgba(30, 64, 175, 0.7);
    }

    html.${CLEAN_CLASS} .topic-post {
        background: rgba(15, 23, 42, 0.96);
        border-color: rgba(30, 64, 175, 0.7);
    }
}

/* =========================================================
   清爽模式隐藏逻辑（样式侧，配合 JS 精准隐藏）
========================================================= */

/* 全局公告 */
html.${CLEAN_CLASS} #global-notice-alert-global-notice.alert,
html.${CLEAN_CLASS} .alert-global-notice {
    display: none !important;
}

/* 帖子列表里头像列 */
html.${CLEAN_CLASS} td.posters.topic-list-data {
    display: none !important;
}

/* 底部分类徽章 */
html.${CLEAN_CLASS} div.link-bottom-line a.badge-category__wrapper {
    display: none !important;
}

/* 标签 */
html.${CLEAN_CLASS} a.discourse-tag.box[href^="/tag/"] {
    display: none !important;
}
        `.trim();
        document.head.appendChild(style);
    }

    /* =============================
     * 动态隐藏相关（仅 linux.do 使用）
     * ============================= */

    function restoreHidden() {
        const list = document.querySelectorAll('[' + HIDDEN_ATTR + ']');
        list.forEach(el => {
            el.style.display = '';
            el.removeAttribute(HIDDEN_ATTR);
        });
    }

    function hideElement(el) {
        if (!el || el.hasAttribute(HIDDEN_ATTR)) return;
        el.style.display = 'none';
        el.setAttribute(HIDDEN_ATTR, '1');
    }

    function applyDynamicHidingLinuxDo() {
        if (!isLinuxDo) return;

        restoreHidden();

        const root = document.getElementById('main-outlet') || document.body;
        if (!root) return;

        /* 隐藏欢迎文案（关键字组合匹配，更耐文案微调） */
        try {
            const keywords = ['希望你喜欢这里', '搜索现有帖子'];
            root.querySelectorAll('p').forEach(p => {
                const text = p.textContent || '';
                if (!text) return;
                let match = true;
                for (const kw of keywords) {
                    if (!text.includes(kw)) {
                        match = false;
                        break;
                    }
                }
                if (match) {
                    hideElement(p);
                }
            });
        } catch (e) {
            // 静默失败，避免影响主流程
        }

        /* 指定推广贴：根据链接 href 匹配并向上找到合理容器隐藏 */
        try {
            const link = root.querySelector('a[href="https://linux.do/t/topic/482293"]');
            if (link) {
                const container = link.closest('tr, article, .topic-list-item, div') || link.parentElement;
                hideElement(container || link);
            }
        } catch (e) {
            // 静默失败
        }
    }

    function setupObserverLinuxDo() {
        if (!isLinuxDo) return;

        const target = document.getElementById('main-outlet') || document.body;
        if (!target || !window.MutationObserver) return;

        let scheduled = false;

        const observer = new MutationObserver(mutations => {
            let hasAdded = false;
            for (const m of mutations) {
                if (m.addedNodes && m.addedNodes.length > 0) {
                    hasAdded = true;
                    break;
                }
            }
            if (!hasAdded) return;

            if (!scheduled) {
                scheduled = true;
                setTimeout(() => {
                    scheduled = false;
                    applyDynamicHidingLinuxDo();
                }, 80);
            }
        });

        observer.observe(target, {
            childList: true,
            subtree: true
        });
    }

    /* =============================
     * 启动函数
     * ============================= */

    function start() {
        injectBaseStyle();
        document.documentElement.classList.add(CLEAN_CLASS);

        if (isLinuxDo) {
            applyDynamicHidingLinuxDo();
            setupObserverLinuxDo();
        }
        // idcflare.com 保留布局与样式优化，不做内容隐藏
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', start, { once: true });
    } else {
        start();
    }
})();
