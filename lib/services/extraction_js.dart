/// Single JS snippet run inside the loaded chapter page. It never touches
/// login/CAPTCHA flows — it only reads whatever the user has already
/// navigated to — and returns a JSON string so Dart can parse it.
///
/// IMPORTANT: evaluateJavascript on some platforms double-encodes the
/// return value; Dart side must use [parseExtractResult] to unwrap it.
const String kExtractChapterJs = r"""
(function () {
  function abs(href) {
    if (!href) return null;
    try { return new URL(href, document.location.href).toString(); }
    catch (e) { return null; }
  }

  function textOf(el) {
    if (!el) return '';
    // Clone and strip junk so we don't pull nav/footer into the body.
    var clone = el.cloneNode(true);
    var junk = clone.querySelectorAll(
      'script,style,nav,header,footer,noscript,iframe,aside,form,button,input,select,textarea,' +
      '.ad,.ads,.advertisement,[class*="comment"],[id*="comment"],[class*="sidebar"],[id*="sidebar"]'
    );
    for (var i = 0; i < junk.length; i++) {
      try { junk[i].remove(); } catch (e) {}
    }
    var t = (clone.innerText || clone.textContent || '').replace(/\r/g, '');
    return t.replace(/\n{3,}/g, '\n\n').trim();
  }

  // --- Body text ---
  var bodySelectors = [
    '#content', '#chaptercontent', '#chapter-content', '#chapter_content',
    '.chapter-content', '.chapter_content', '.chaptercontent',
    '#booktext', '#BookText', '.readcontent', '.read-content',
    '.novel-content', '.book-content', '#htmlContent', '#TextContent',
    'article', '.content', '.txt', '.text', '.chapter', '#chapters'
  ];
  var bodyEl = null;
  for (var i = 0; i < bodySelectors.length; i++) {
    var el = document.querySelector(bodySelectors[i]);
    if (el && textOf(el).length > 40) { bodyEl = el; break; }
  }
  var bodyText = bodyEl ? textOf(bodyEl) : '';

  // Fallback: largest texty div/section, ignoring nav/footer/ads.
  if (bodyText.length < 40) {
    var candidates = Array.prototype.slice.call(document.querySelectorAll('div,section'));
    var best = null, bestLen = 0;
    candidates.forEach(function (el) {
      var tag = ((el.className || '') + ' ' + (el.id || '')).toString();
      if (/nav|footer|header|ad|comment|menu|sidebar|toolbar/i.test(tag)) return;
      var len = textOf(el).length;
      if (len > bestLen) { bestLen = len; best = el; }
    });
    if (best && bestLen > 40) bodyText = textOf(best);
  }

  // --- Novel (book) title + chapter number ---
  var chapterLike = /第\s*[0-9零〇一二两兩三四五六七八九十百千万萬亿]+\s*[章节節話话回]|chapter\s*[0-9]|ch\.\s*[0-9]/i;

  function metaContent(sel) {
    var m = document.querySelector(sel);
    return m ? (m.getAttribute('content') || '').trim() : '';
  }

  function cleanTitle(t) {
    return (t || '')
      .replace(/[\s\u3000]+/g, ' ')
      .replace(/^[\[\(【《]+|[\]\)】》]+$/g, '')
      .trim();
  }

  function findBookTitle() {
    var v = metaContent('meta[property="og:novel:book_name"]') ||
            metaContent('meta[property="og:book:title"]') ||
            metaContent('meta[name="og:novel:book_name"]') ||
            metaContent('meta[name="book_name"]') ||
            metaContent('meta[name="bookname"]');
    if (v) return cleanTitle(v);

    var sels = [
      '.book-title', '.booktitle', '.book_title', '.novel-title',
      '.novel_title', '#bookname a', '#bookname', '.bookname a',
      '.bookname', '.book-name', '.book_name', '[itemprop="name"]'
    ];
    for (var i = 0; i < sels.length; i++) {
      var el = document.querySelector(sels[i]);
      if (el) {
        var t = cleanTitle(el.innerText || el.textContent || '');
        if (t && t.length < 80 && !chapterLike.test(t)) return t;
      }
    }

    // Breadcrumbs: last non-chapter-looking link.
    var crumbBox = document.querySelector(
      '.breadcrumb, .breadcrumbs, .crumbs, .con_top, #bread, [class*="breadcrumb"]'
    );
    if (crumbBox) {
      var links = crumbBox.querySelectorAll('a');
      for (var j = links.length - 1; j >= 0; j--) {
        var lt = cleanTitle(links[j].innerText || links[j].textContent || '');
        if (lt && lt.length < 80 && !chapterLike.test(lt) &&
            !/首页|首頁|home|目录|目錄|index/i.test(lt)) {
          return lt;
        }
      }
    }

    // Fallback: parse document.title, dropping the trailing site name.
    var raw = cleanTitle(document.title || '');
    if (!raw) return '';
    var parts = raw.split(/\s*[|\-–—_»>·・~]\s*/)
      .map(function (s) { return s.trim(); })
      .filter(function (s) { return s.length > 0; });
    if (parts.length <= 1) return raw;
    var candidates = parts.slice(0, parts.length - 1);
    for (var k = candidates.length - 1; k >= 0; k--) {
      if (!chapterLike.test(candidates[k])) return candidates[k];
    }
    return candidates[candidates.length - 1] || parts[0];
  }

  function findChapterTitle() {
    var sels = [
      '.bookname h1', '#chapter-title', '.chapter-title', '.chapter_title',
      '.chaptertitle', 'h1.title', '.content h1', 'h1', 'h2'
    ];
    for (var i = 0; i < sels.length; i++) {
      var el = document.querySelector(sels[i]);
      if (el) {
        var t = cleanTitle(el.innerText || el.textContent || '');
        if (t.length >= 2 && t.length < 120) return t;
      }
    }
    var raw = cleanTitle(document.title || '');
    if (!raw) return '';
    var parts = raw.split(/\s*[|\-–—_»>·・~]\s*/)
      .map(function (s) { return s.trim(); })
      .filter(function (s) { return s.length > 0; });
    for (var j = 0; j < parts.length; j++) {
      if (chapterLike.test(parts[j])) return parts[j];
    }
    return parts.length > 0 ? parts[0] : raw;
  }

  var cnDigits = {
    '零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '兩': 2, '三': 3, '四': 4,
    '五': 5, '六': 6, '七': 7, '八': 8, '九': 9
  };
  var cnUnits = { '十': 10, '百': 100, '千': 1000, '万': 10000, '萬': 10000, '亿': 100000000 };

  function cnToNum(s) {
    if (/^[0-9]+$/.test(s)) return parseInt(s, 10);
    var total = 0, section = 0, number = 0, seen = false;
    for (var i = 0; i < s.length; i++) {
      var ch = s.charAt(i);
      if (cnDigits[ch] !== undefined) {
        number = cnDigits[ch];
        seen = true;
      } else if (cnUnits[ch] !== undefined) {
        var unit = cnUnits[ch];
        seen = true;
        if (unit >= 10000) {
          section = (section + number) * unit;
          total += section;
          section = 0;
        } else {
          if (number === 0) number = 1;
          section += number * unit;
        }
        number = 0;
      } else {
        return null;
      }
    }
    if (!seen) return null;
    return total + section + number;
  }

  function findChapterNumber() {
    var sources = [];
    var heads = document.querySelectorAll('h1, h2, .chapter-title, .bookname h1, #chapter-title');
    for (var i = 0; i < heads.length && i < 4; i++) {
      sources.push((heads[i].innerText || heads[i].textContent || '').trim());
    }
    sources.push(document.title || '');
    for (var j = 0; j < sources.length; j++) {
      var s = sources[j];
      if (!s) continue;
      var m = s.match(/第\s*([0-9]+|[零〇一二两兩三四五六七八九十百千万萬亿]+)\s*[章节節話话回]/);
      if (m) {
        var n = cnToNum(m[1]);
        if (n !== null && n > 0) return String(n);
      }
      m = s.match(/\b(?:chapter|chap|ch|episode|ep)\.?\s*([0-9]{1,5}(?:\.[0-9]{1,2})?)/i);
      if (m) return m[1];
    }
    return '';
  }

  // --- Prev / Next / TOC links ---
  var prevPatterns = /上一章|上一頁|上一页|Previous\s*Chapter|Prev\s*Chapter|^Prev$|«\s*Prev|prior\s*chapter/i;
  var nextPatterns = /下一章|下一頁|下一页|Next\s*Chapter|^Next$|次章|Next\s*»/i;
  var tocPatterns = /目录|目錄|Table\s*of\s*Contents|^TOC$|章节目录|章節目錄|Chapter\s*List|Index/i;

  var prevUrl = null, nextUrl = null, tocUrl = null;

  var relPrev = document.querySelector('a[rel="prev"]');
  var relNext = document.querySelector('a[rel="next"]');
  if (relPrev) prevUrl = abs(relPrev.getAttribute('href'));
  if (relNext) nextUrl = abs(relNext.getAttribute('href'));

  var anchors = Array.prototype.slice.call(document.querySelectorAll('a[href]'));
  anchors.forEach(function (a) {
    var label = ((a.innerText || '') + ' ' + (a.getAttribute('aria-label') || '') + ' ' + (a.getAttribute('title') || '')).trim();
    var href = a.getAttribute('href') || '';
    if (!prevUrl && prevPatterns.test(label)) prevUrl = abs(href);
    if (!nextUrl && nextPatterns.test(label)) nextUrl = abs(href);
    if (!tocUrl && (tocPatterns.test(label) || /\/(toc|index|chapter-list|chapters)(\/|$|\?)/i.test(href))) {
      tocUrl = abs(href);
    }
  });

  // Avoid treating javascript: or empty anchors as navigation.
  function sane(u) {
    if (!u) return null;
    if (/^(javascript:|#|mailto:)/i.test(u)) return null;
    return u;
  }

  return JSON.stringify({
    bodyText: bodyText,
    pageTitle: document.title || '',
    bookTitle: findBookTitle(),
    chapterTitle: findChapterTitle(),
    chapterNumber: findChapterNumber(),
    prevUrl: sane(prevUrl),
    nextUrl: sane(nextUrl),
    tocUrl: sane(tocUrl)
  });
})();
""";
