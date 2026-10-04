import React from 'react';
import {useCurrentFrame} from 'remotion';
import {springIn} from '../anim';
import {C, FONT} from '../theme';

/** 金色高亮字 */
export const Hl: React.FC<{children: React.ReactNode; color?: string}> = ({children, color = C.gold}) => (
  <span style={{color}}>{children}</span>
);

/**
 * 场景顶部的标题区：小标签 + 两行大字，逐行上滑淡入。
 * 放在抖音/小红书顶部安全区以下（y≈170 起）。
 */
export const Headline: React.FC<{
  kicker?: string;
  index?: string;
  lines: React.ReactNode[];
  sub?: React.ReactNode;
  top?: number;
  size?: number;
  start?: number;
}> = ({kicker, index, lines, sub, top = 170, size = 96, start = 0}) => {
  const frame = useCurrentFrame();
  const k = springIn(frame, start);
  return (
    <div
      style={{
        position: 'absolute',
        top,
        left: 0,
        right: 0,
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        fontFamily: FONT,
        color: C.white,
        textAlign: 'center',
      }}
    >
      {kicker ? (
        <div
          style={{
            opacity: k,
            transform: `translateY(${(1 - k) * 20}px)`,
            display: 'flex',
            alignItems: 'center',
            gap: 14,
            padding: '10px 26px 10px 12px',
            borderRadius: 999,
            background: 'rgba(255,255,255,0.08)',
            border: '1.5px solid rgba(255,255,255,0.16)',
            fontSize: 34,
            fontWeight: 600,
            letterSpacing: 2,
            marginBottom: 30,
          }}
        >
          {index ? (
            <span
              style={{
                background: C.gold,
                color: '#1d1503',
                borderRadius: 999,
                padding: '4px 16px',
                fontSize: 28,
                fontWeight: 700,
                fontFamily: '-apple-system, "SF Pro Display", sans-serif',
              }}
            >
              {index}
            </span>
          ) : null}
          <span style={{color: C.mint}}>{kicker}</span>
        </div>
      ) : null}
      {lines.map((line, i) => {
        const p = springIn(frame, start + 5 + i * 6, 20);
        return (
          <div
            key={i}
            style={{
              opacity: p,
              transform: `translateY(${(1 - p) * 46}px)`,
              fontSize: size,
              fontWeight: 600,
              lineHeight: 1.18,
              letterSpacing: 3,
              textShadow: '0 6px 30px rgba(0,0,0,0.35)',
            }}
          >
            {line}
          </div>
        );
      })}
      {sub ? (
        <div
          style={{
            opacity: springIn(frame, start + 18),
            marginTop: 22,
            fontSize: 38,
            fontWeight: 500,
            color: C.dim,
            letterSpacing: 2,
          }}
        >
          {sub}
        </div>
      ) : null}
    </div>
  );
};
