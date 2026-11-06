// 明暗主题切换
document.addEventListener('DOMContentLoaded', function () {
  var btn = document.getElementById('theme-toggle')
  if (!btn) return

  function current() {
    return document.documentElement.getAttribute('data-theme') === 'dark' ? 'dark' : 'light'
  }

  function sync() {
    btn.setAttribute('aria-pressed', String(current() === 'dark'))
  }

  btn.addEventListener('click', function () {
    var next = current() === 'dark' ? 'light' : 'dark'
    document.documentElement.setAttribute('data-theme', next)
    try {
      localStorage.setItem('theme', next)
    } catch (err) {
      // localStorage 不可用时忽略
    }
    sync()
  })

  sync()
})

// 同步吸顶头部实际高度，供锚点偏移（scroll-margin-top）使用
function syncHeaderH() {
  var h = document.querySelector('.site-header')
  if (h) document.documentElement.style.setProperty('--header-h', h.offsetHeight + 'px')
}
window.addEventListener('resize', syncHeaderH)
syncHeaderH()
