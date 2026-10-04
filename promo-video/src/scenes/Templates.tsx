import React from 'react';
import {AbsoluteFill, Img, staticFile, useCurrentFrame} from 'remotion';
import {pop, springIn} from '../anim';
import {Background} from '../components/Background';
import {Chip} from '../components/Chip';
import {Headline, Hl} from '../components/Headline';
import {IconCheck, IconGlobe} from '../components/Icons';
import {Phone, Shot} from '../components/Phone';
import {C} from '../theme';

const PHONE_W = 700;
const PHONE_TOP = 640;
const TPL_FRAMES = 163;

// 两侧漂浮的模板卡面（都是 App 内置模板自带的卡图）
const FLOAT = [
  {src: 'cards/CSP.png', x: 40, y: 760, r: -14, d: 0},
  {src: 'cards/hsbchkred.png', x: 760, y: 700, r: 12, d: 4},
  {src: 'cards/amexgreen.png', x: 10, y: 1060, r: 10, d: 8},
  {src: 'cards/ChaseBoundless.jpeg', x: 790, y: 1000, r: -10, d: 12},
  {src: 'cards/amexusaspire.jpeg', x: 30, y: 1360, r: -8, d: 16},
  {src: 'cards/sccathay.jpeg', x: 780, y: 1300, r: 14, d: 20},
  {src: 'cards/citiaaexecutive.jpeg', x: 0, y: 1660, r: 12, d: 24},
  {src: 'cards/ccbtravo.png', x: 800, y: 1600, r: -12, d: 28},
];
const FW = 300;

/** 30–36s：内置卡模板 */
export const Templates: React.FC = () => {
  const frame = useCurrentFrame();
  const phoneIn = springIn(frame, 0, 22);

  return (
    <AbsoluteFill>
      <Background accent={C.gold} glowY={0.5} />
      <Headline index="04" kicker="内置卡模板" lines={['40+ 热门信用卡', <><Hl>一键</Hl>添加</>]} />

      {FLOAT.map((c) => {
        const p = pop(frame, 6 + c.d);
        const drift = -frame * 0.9;
        return (
          <div
            key={c.src}
            style={{
              position: 'absolute',
              left: c.x + (c.x < 500 ? -(1 - p) * 300 : (1 - p) * 300),
              top: c.y + drift,
              width: FW,
              height: FW / 1.586,
              borderRadius: FW * 0.048,
              overflow: 'hidden',
              transform: `rotate(${c.r}deg)`,
              boxShadow: '0 20px 50px rgba(0,0,0,0.5)',
              opacity: Math.min(1, p) * 0.92,
            }}
          >
            <Img src={staticFile(c.src)} style={{width: '100%', height: '100%', objectFit: 'cover'}} />
          </div>
        );
      })}

      <div
        style={{
          position: 'absolute',
          left: (1080 - PHONE_W) / 2,
          top: PHONE_TOP + (1 - phoneIn) * 240,
          opacity: phoneIn,
        }}
      >
        <Phone width={PHONE_W}>
          {/* 模拟器录屏拆成的序列帧（30fps）。不用 OffthreadVideo：磁盘紧张时 Chrome 取大帧会失败 */}
          <Shot src={`screens/tpl/${String(Math.min(TPL_FRAMES, Math.max(1, frame - 10 + 1))).padStart(3, '0')}.jpg`} />
        </Phone>
      </div>

      <div
        style={{
          position: 'absolute',
          top: 1330,
          left: 0,
          right: 0,
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          gap: 26,
        }}
      >
        <div style={{opacity: springIn(frame, 44), transform: `translateY(${(1 - springIn(frame, 44)) * 30}px)`}}>
          <Chip tone="gold" size={38} icon={<IconCheck size={38} strokeWidth={3} />}>
            费率 · 类别加成 · 上限 自动填好
          </Chip>
        </div>
        <div style={{opacity: springIn(frame, 60), transform: `translateY(${(1 - springIn(frame, 60)) * 30}px)`}}>
          <Chip size={34} icon={<IconGlobe size={36} />}>
            美国 · 香港 · 大陆 · 日本
          </Chip>
        </div>
      </div>
    </AbsoluteFill>
  );
};
