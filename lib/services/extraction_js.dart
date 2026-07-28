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
    prevUrl: sane(prevUrl),
    nextUrl: sane(nextUrl),
    tocUrl: sane(tocUrl)
  });
})();
""";
