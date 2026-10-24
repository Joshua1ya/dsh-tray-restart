/**
 * Client half of dsh-tray-restart: one "restart" control in the Session header toolbar.
 *
 * The button posts to the Host half's `/dsh-tray-restart/restart` route, which asks Windows to
 * run the restart helper outside the app's process tree. The page disappears a moment later,
 * so the control only needs to look busy until the connection drops.
 */
window.__ModuleLoader__.load({
  id: 'dsh-tray-restart',
  factory(require) {
    const React = require('react')
    const h = React.createElement
    const { useCallback, useState } = React

    const ZH = /^zh\b/i.test(navigator.language || '')
    const TITLE = ZH
      ? '重启 DeepSeek Harness（应用 + Host）'
      : 'Restart DeepSeek Harness (app + host)'
    const FAILED = ZH ? '重启失败，详情见 %TEMP%\\dsh-tray-restart.log' : 'Restart failed, see %TEMP%\\dsh-tray-restart.log'
    const SPIN = '@keyframes dsh-tray-restart-spin{to{transform:rotate(360deg)}}'

    function Glyph({ spinning }) {
      return h(
        'svg',
        {
          viewBox: '0 0 16 16',
          width: 16,
          height: 16,
          fill: 'none',
          stroke: 'currentColor',
          strokeWidth: 1.6,
          strokeLinecap: 'round',
          strokeLinejoin: 'round',
          'aria-hidden': true,
          style: {
            display: 'block',
            animation: spinning ? 'dsh-tray-restart-spin .9s linear infinite' : undefined,
          },
        },
        h('path', { d: 'M13.2 8a5.2 5.2 0 1 1-1.7-3.9' }),
        h('path', { d: 'M13.4 2.6v2.9h-2.9' }),
      )
    }

    function RestartButton() {
      const [phase, setPhase] = useState('idle')
      const [hover, setHover] = useState(false)
      const failed = phase === 'failed'

      const onClick = useCallback(async () => {
        if (phase === 'busy' || phase === 'restarting') return
        setPhase('busy')
        try {
          const res = await fetch('/dsh-tray-restart/restart', {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: '{}',
          })
          const body = await res.json().catch(() => ({}))
          if (!res.ok || body.ok !== true) throw new Error(body.reason || `HTTP ${res.status}`)
          // The application is closing; keep the busy state until the page goes away.
          setPhase('restarting')
        } catch (error) {
          console.warn('[dsh-tray-restart] restart failed:', error)
          setPhase('failed')
          window.setTimeout(() => setPhase('idle'), 4000)
        }
      }, [phase])

      return h(
        React.Fragment,
        null,
        h('style', null, SPIN),
        h(
          'button',
          {
            type: 'button',
            className: 'dsh-tray-restart__button',
            title: failed ? FAILED : TITLE,
            'aria-label': TITLE,
            onClick,
            onMouseEnter: () => setHover(true),
            onMouseLeave: () => setHover(false),
            style: {
              display: 'inline-flex',
              alignItems: 'center',
              justifyContent: 'center',
              width: 28,
              height: 28,
              padding: 0,
              border: 'none',
              borderRadius: 6,
              background: hover || phase !== 'idle' ? 'var(--dsh-color-fill-2, rgba(127,127,127,.18))' : 'transparent',
              color: failed ? 'var(--dsh-color-danger, #e5484d)' : 'inherit',
              opacity: phase === 'idle' && !hover ? 0.72 : 1,
              cursor: phase === 'busy' || phase === 'restarting' ? 'progress' : 'pointer',
              transition: 'opacity .15s ease, background .15s ease',
            },
          },
          h(Glyph, { spinning: phase === 'busy' || phase === 'restarting' }),
        ),
      )
    }

    return {
      inject: ['slots'],
      apply(ctx) {
        ctx.slots.inject('conversation.session.header.utilities', () =>
          ctx.slots.register(
            { name: 'conversation.session.header.utilities', id: 'dsh-tray-restart', order: 20 },
            RestartButton,
          ),
        )
      },
    }
  },
})
