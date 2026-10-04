import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {C} from '../theme';

/** 墨绿渐变底 + 一团跟场景走的主色光晕，缓慢漂移 */
export const Background: React.FC<{accent?: string; glowY?: number}> = ({accent = C.green, glowY = 0.42}) => {
  const frame = useCurrentFrame();
  const drift = Math.sin(frame / 50) * 40;
  return (
    <AbsoluteFill style={{background: `linear-gradient(180deg, ${C.bg1} 0%, ${C.bg0} 70%)`}}>
      <AbsoluteFill
        style={{
          background: `radial-gradient(circle at ${50 + drift / 20}% ${glowY * 100}%, ${accent}55 0%, ${accent}18 32%, transparent 62%)`,
        }}
      />
      <AbsoluteFill
        style={{
          background: `radial-gradient(circle at ${85 - drift / 30}% 8%, ${C.gold}22 0%, transparent 35%)`,
        }}
      />
      {/* 细网格，增加一点质感 */}
      <AbsoluteFill
        style={{
          opacity: 0.06,
          backgroundImage:
            'linear-gradient(rgba(255,255,255,0.6) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.6) 1px, transparent 1px)',
          backgroundSize: '72px 72px',
          maskImage: 'radial-gradient(circle at 50% 35%, black 0%, transparent 70%)',
          WebkitMaskImage: 'radial-gradient(circle at 50% 35%, black 0%, transparent 70%)',
        }}
      />
    </AbsoluteFill>
  );
};
