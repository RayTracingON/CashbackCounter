import React from 'react';
import {AbsoluteFill, Img, staticFile, useCurrentFrame} from 'remotion';
import {pop, springIn} from '../anim';
import {Background} from '../components/Background';
import {Chip} from '../components/Chip';
import {Hl} from '../components/Headline';
import {IconBolt, IconCard, IconRefresh, IconSparkle} from '../components/Icons';
import {C, FONT} from '../theme';

const RECAP = [
  {icon: <IconBolt size={34} />, text: '快捷指令记账'},
  {icon: <IconRefresh size={34} />, text: '美国银行同步'},
  {icon: <IconSparkle size={34} />, text: '端侧 + 云端 AI'},
  {icon: <IconCard size={34} />, text: '40+ 卡模板'},
];

const Fade: React.FC<{at: number; children: React.ReactNode; style?: React.CSSProperties}> = ({at, children, style}) => {
  const frame = useCurrentFrame();
  const p = springIn(frame, at);
  return <div style={{opacity: p, transform: `translateY(${(1 - p) * 30}px)`, ...style}}>{children}</div>;
};

/** 36–40s：图标 + 名字 + 下载引导 */
export const Outro: React.FC = () => {
  const frame = useCurrentFrame();
  const iconP = pop(frame, 4);
  return (
    <AbsoluteFill style={{fontFamily: FONT, color: C.white}}>
      <Background accent={C.gold} glowY={0.36} />
      <AbsoluteFill style={{display: 'flex', flexDirection: 'column', alignItems: 'center', paddingTop: 330}}>
        <div
          style={{
            width: 300,
            height: 300,
            borderRadius: 300 * 0.2237,
            overflow: 'hidden',
            transform: `scale(${0.6 + iconP * 0.4})`,
            opacity: Math.min(1, iconP * 1.5),
            boxShadow: `0 40px 100px rgba(0,0,0,0.55), 0 0 90px ${C.gold}44`,
          }}
        >
          <Img src={staticFile('icon.png')} style={{width: '100%', height: '100%'}} />
        </div>
        <Fade at={12} style={{marginTop: 56, fontSize: 92, fontWeight: 600, letterSpacing: 1}}>
          Cashback Counter
        </Fade>
        <Fade at={17} style={{marginTop: 8, fontSize: 46, fontWeight: 500, color: C.mint, letterSpacing: 6}}>
          返现小助手
        </Fade>
        <Fade at={24} style={{marginTop: 54, fontSize: 60, fontWeight: 600, letterSpacing: 3}}>
          每一笔，都算得<Hl>明明白白</Hl>
        </Fade>
        <div style={{marginTop: 60, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 22}}>
          {RECAP.map((r, i) => (
            <Fade key={r.text} at={32 + i * 4}>
              <Chip size={32} icon={r.icon} style={{width: '100%', boxSizing: 'border-box', justifyContent: 'center'}}>
                {r.text}
              </Chip>
            </Fade>
          ))}
        </div>
        <Fade at={52} style={{marginTop: 70}}>
          <Chip tone="gold" size={42}>
            App Store 搜索「Cashback Counter」
          </Chip>
        </Fade>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
