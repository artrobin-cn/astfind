(function () {
  'use strict';

  var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var staticMode = new URLSearchParams(window.location.search).has('noanim');
  var hasGsap = typeof window.gsap !== 'undefined' && typeof window.ScrollTrigger !== 'undefined';
  if (staticMode) document.documentElement.classList.add('no-anim');

  /* sticky nav state */
  var nav = document.getElementById('nav');
  function updateNav() {
    if (!nav) return;
    nav.classList.toggle('is-scrolled', window.scrollY > 8);
  }
  updateNav();
  window.addEventListener('scroll', updateNav, { passive: true });

  /* copy buttons */
  var toast = document.getElementById('toast');
  var toastTimer = 0;
  function showToast(message) {
    if (!toast) return;
    toast.textContent = message;
    toast.classList.add('is-visible');
    window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(function () {
      toast.classList.remove('is-visible');
    }, 1800);
  }
  function fallbackCopy(text) {
    var area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.top = '-1000px';
    document.body.appendChild(area);
    area.select();
    try { document.execCommand('copy'); } catch (error) { /* no-op */ }
    document.body.removeChild(area);
  }
  document.querySelectorAll('.copy').forEach(function (button) {
    button.addEventListener('click', function () {
      var target = document.querySelector(button.getAttribute('data-copy'));
      var text = target ? target.textContent.trim() : '';
      if (!text) return;
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).catch(function () { fallbackCopy(text); });
      } else {
        fallbackCopy(text);
      }
      button.textContent = '已复制';
      button.classList.add('is-done');
      showToast('已复制：' + text);
      window.setTimeout(function () {
        button.textContent = '复制';
        button.classList.remove('is-done');
      }, 1600);
    });
  });

  /* hero demo: loop the real panel states through a single image (no video/layer compositing) */
  var heroLive = document.getElementById('hero-live');
  if (heroLive && !reduceMotion && !staticMode) {
    var heroFrames = [
      ['assets/shots/hero-frames/00-empty.png?v=20261104', 900],
      ['assets/shots/hero-frames/01-deep.png?v=20261104', 700],
      ['assets/shots/hero-frames/02-deep-sky.png?v=20261104', 600],
      ['assets/shots/hero-frames/03-deep-blue.png?v=20261104', 600],
      ['assets/shots/hero-frames/04-final.png?v=20261104', 3200]
    ];
    heroFrames.forEach(function (frame) { var preload = new Image(); preload.src = frame[0]; });
    var heroIndex = 0;
    var heroTimer = 0;
    var advanceHero = function () {
      heroIndex = (heroIndex + 1) % heroFrames.length;
      heroLive.src = heroFrames[heroIndex][0];
      heroTimer = window.setTimeout(advanceHero, heroFrames[heroIndex][1]);
    };
    heroTimer = window.setTimeout(advanceHero, heroFrames[0][1]);
  }

  if (!hasGsap || reduceMotion || staticMode) return;

  try {
    document.documentElement.classList.add('js');
    gsap.registerPlugin(ScrollTrigger);
    ScrollTrigger.config({ ignoreMobileResize: true });

    /* hero entrance */
    gsap.from('.hero-copy > *', {
      y: 18, opacity: 0, duration: 0.7, stagger: 0.06, ease: 'power3.out'
    });
    gsap.from('#hero-figure', {
      y: 28, opacity: 0, duration: 0.9, delay: 0.16, ease: 'power3.out',
      clearProps: 'transform,opacity'
    });

    /* section heads */
    gsap.utils.toArray('.section-head').forEach(function (head) {
      gsap.from(head, {
        y: 22, opacity: 0, duration: 0.7, ease: 'power2.out',
        immediateRender: false,
        scrollTrigger: { trigger: head, start: 'top 84%', once: true }
      });
    });

    /* channel rows */
    gsap.from('.channel-row', {
      y: 16, opacity: 0, duration: 0.5, stagger: 0.07, ease: 'power2.out',
      immediateRender: false,
      scrollTrigger: { trigger: '.channel-list', start: 'top 82%', once: true }
    });

    /* screenshots: curtain reveal + slight scale settle */
    gsap.utils.toArray('.shot-multi .shot-frame, .shot-offline .shot-frame').forEach(function (frame) {
      gsap.fromTo(frame,
        { clipPath: 'inset(0 0 100% 0)' },
        {
          clipPath: 'inset(0 0 0% 0)', duration: 0.9, ease: 'power3.inOut',
          immediateRender: false,
          scrollTrigger: { trigger: frame, start: 'top 84%', once: true },
          onComplete: function () { gsap.set(frame, { clearProps: 'clipPath' }); }
        });
      var image = frame.querySelector('img');
      if (image) {
        gsap.from(image, {
          scale: 1.04, duration: 1.2, ease: 'power2.out',
          immediateRender: false,
          scrollTrigger: { trigger: frame, start: 'top 84%', once: true }
        });
      }
    });

    /* image search: desktop scroll narrative; mobile uses the static stacked layout */
    var stage = document.getElementById('image-stage');
    var isMobile = window.matchMedia('(max-width: 820px)').matches;
    if (stage && !isMobile) {
      var referenceImage = document.querySelector('#reference-media > img');
      var cropBox = document.getElementById('crop-box');
      var chip = document.getElementById('reference-chip');
      var stepLabel = document.getElementById('stage-step');
      var result = document.getElementById('image-result');
      var media = document.getElementById('reference-media');

      gsap.set(cropBox, { top: 0, right: 0, bottom: 0, left: 0 });
      gsap.set(result, { y: '12vh', scale: 0.62 });

      var timeline = gsap.timeline({
        scrollTrigger: {
          trigger: stage,
          start: 'top top',
          end: '+=125%',
          pin: true,
          scrub: true,
          anticipatePin: 1,
          invalidateOnRefresh: true
        }
      });
      timeline.fromTo(referenceImage, { scale: 1 }, {
        scale: 1.55, ease: 'power1.inOut', duration: 1
      }, 0);
      timeline.to(cropBox, {
        top: '30%', right: '24%', bottom: '34%', left: '22%',
        duration: 0.55, ease: 'power2.inOut'
      }, 0.08);
      timeline.to(chip, { opacity: 1, y: 0, duration: 0.14 }, 0.38);
      ScrollTrigger.create({
        trigger: stage,
        start: 'top top',
        end: '+=125%',
        onUpdate: function (self) {
          if (!stepLabel) return;
          stepLabel.textContent = self.progress >= 0.36 ? '02 · 找它出现过的所有地方' : '01 · 框住画面的一角';
        }
      });
      timeline.to(media, { autoAlpha: 0, duration: 0.12 }, 0.5);
      timeline.fromTo(result,
        { y: '12vh', scale: 0.62, opacity: 0 },
        { y: 0, scale: 1, opacity: 1, duration: 0.32, ease: 'power3.out' }, 0.56);
    }

    /* sources */
    gsap.from('.source-stats', {
      y: 18, opacity: 0, duration: 0.6, ease: 'power2.out',
      immediateRender: false,
      scrollTrigger: { trigger: '.source-stats', start: 'top 84%', once: true }
    });

    /* privacy */
    gsap.from('.privacy-head', {
      y: 20, opacity: 0, duration: 0.7, ease: 'power2.out',
      immediateRender: false,
      scrollTrigger: { trigger: '.privacy', start: 'top 75%', once: true }
    });
    gsap.from('.privacy-points li', {
      y: 14, opacity: 0, duration: 0.55, stagger: 0.07, ease: 'power2.out',
      immediateRender: false,
      scrollTrigger: { trigger: '.privacy-points', start: 'top 82%', once: true }
    });

    /* benchmark */
    gsap.from('.benchmark-table', {
      y: 16, opacity: 0, duration: 0.7, ease: 'power2.out',
      immediateRender: false,
      scrollTrigger: { trigger: '.table-wrap', start: 'top 82%', once: true }
    });

    /* install + endcap */
    gsap.from('.install-card', {
      y: 18, opacity: 0, duration: 0.6, stagger: 0.08, ease: 'power2.out',
      immediateRender: false,
      scrollTrigger: { trigger: '.install-grid', start: 'top 84%', once: true }
    });
    gsap.from('.endcap .endcap-icon, .endcap h2, .endcap .hero-actions, .endcap .hotkey', {
      y: 18, opacity: 0, duration: 0.6, stagger: 0.07, ease: 'power2.out',
      immediateRender: false,
      scrollTrigger: { trigger: '.endcap', start: 'top 78%', once: true }
    });

    window.addEventListener('load', function () { ScrollTrigger.refresh(); });
  } catch (error) {
    document.documentElement.classList.remove('js');
    console.warn('Astfind landing animations unavailable:', error);
  }
})();
