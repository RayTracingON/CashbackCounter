import React from 'react';
import {C, FONT} from '../theme';

/** 毛玻璃胶囊标签：图标 + 文案 */
export const Chip: React.FC<{
  icon?: React.ReactNode;
  children: React.ReactNode;
  style?: React.CSSProperties;
  size?: number;
  tone?: 'glass' | 'gold' | 'mint';
}> = ({icon, children, style, size = 34, tone = 'glass'}) => {
  const tones = {
    // 底色要不透明：标签经常压在白色的 App 截图上
    glass: {bg: 'rgba(10,30,23,0.93)', border: 'rgba(255,255,255,0.2)', color: C.white, iconColor: C.mint},
    gold: {bg: 'rgba(52,40,9,0.95)', border: 'rgba(244,201,93,0.75)', color: '#FFE3A0', iconColor: C.gold},
    mint: {bg: 'rgba(8,40,27,0.94)', border: 'rgba(126,226,168,0.6)', color: '#D5F7E3', iconColor: C.mint},
  }[tone];
  return (
    <div
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 14,
        padding: `${size * 0.42}px ${size * 0.8}px ${size * 0.42}px ${size * 0.62}px`,
        borderRadius: 999,
        background: tones.bg,
        border: `1.5px solid ${tones.border}`,
        backdropFilter: 'blur(18px)',
        WebkitBackdropFilter: 'blur(18px)',
        boxShadow: '0 14px 40px rgba(0,0,0,0.35)',
        fontFamily: FONT,
        fontSize: size,
        fontWeight: 600,
        color: tones.color,
        letterSpacing: 1,
        whiteSpace: 'nowrap',
        ...style,
      }}
    >
      {icon ? <span style={{display: 'flex', color: tones.iconColor}}>{icon}</span> : null}
      {children}
    </div>
  );
};
