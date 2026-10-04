import React from 'react';
import {AbsoluteFill, Img, staticFile, useCurrentFrame} from 'remotion';
import {ease, pop, springIn} from '../anim';
import {Background} from '../components/Background';
import {Chip} from '../components/Chip';
import {Headline, Hl} from '../components/Headline';
import {IconCheck} from '../components/Icons';
import {C} from '../theme';

const CARDS = [
  'cards/AMEXP.jpeg',
  'cards/ChaseFreedomFlex.png',
  'cards/AppleCard.png',
  'cards/amexgold.png',
  'cards/CSR.jpeg',
  'cards/CapitalOneVentureX.png',
];

const CARD_W = 440;
const CARD_H = CARD_W / 1.586;

/** 0–4s：六张卡扇形飞入 + 「刷完卡，账已经记好了」 */
export const Hook: React.FC = () => {
  const frame = useCurrentFrame();
  const n = CARDS.length;

  return (
    <AbsoluteFill>
      <Background accent={C.gold} glowY={0.66} />
      <Headline
        top={300}
        size={116}
        lines={['刷完卡，', <>账已经<Hl>记好了</Hl></>]}
        sub="返现 · 积分 · 上限，自动算清"
      />

      {CARDS.map((src, i) => {
        const p = pop(frame, 6 + i * 4);
        // 扇形：绕卡片下方远处的一点旋转
        const angle = (i - (n - 1) / 2) * 6.5;
        const breathe = Math.sin((frame - i * 6) / 22) * 1.2;
        const fly = (1 - p) * 900;
        const isTop = i === n - 1;
        const lift = isTop ? ease(frame, 58, 72) * -70 : 0;
        return (
          <div
            key={src}
            style={{
              position: 'absolute',
              left: 540 - CARD_W / 2,
              top: 1150 + fly + lift,
              width: CARD_W,
              height: CARD_H,
              transformOrigin: '50% 320%',
              transform: `rotate(${(angle + breathe) * p}deg)`,
              borderRadius: CARD_W * 0.048,
              overflow: 'hidden',
              boxShadow: isTop
                ? `0 30px 80px rgba(0,0,0,0.55), 0 0 ${ease(frame, 58, 72) * 70}px ${C.gold}88`
                : '0 24px 60px rgba(0,0,0,0.5)',
              opacity: Math.min(1, p * 1.5),
            }}
          >
            <Img src={staticFile(src)} style={{width: '100%', height: '100%', objectFit: 'cover'}} />
          </div>
        );
      })}

      {/* 最上面那张抬起后弹出「已自动记账」 */}
      <div
        style={{
          position: 'absolute',
          top: 1010,
          left: 0,
          right: 0,
          display: 'flex',
          justifyContent: 'center',
          opacity: springIn(frame, 70),
          transform: `translateY(${(1 - springIn(frame, 70)) * 30}px) scale(${0.9 + pop(frame, 70) * 0.1})`,
        }}
      >
        <Chip tone="gold" size={40} icon={<IconCheck size={40} strokeWidth={3} />}>
          已自动记账 · 返现价值 +$0.24
        </Chip>
      </div>
    </AbsoluteFill>
  );
};
