import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {ease, easeInOut, lin, pop, springIn} from '../anim';
import {Background} from '../components/Background';
import {Chip} from '../components/Chip';
import {Headline, Hl} from '../components/Headline';
import {IconCheck, IconPhone} from '../components/Icons';
import {Phone, screenWidthOf, Shot, ShotCrop} from '../components/Phone';
import {Spinner} from '../components/Spinner';
import {BILL, C, FONT, SHOT_W} from '../theme';

const PHONE_W = 780;
const PHONE_TOP = 640;
const SCREEN_W = screenWidthOf(PHONE_W);
const K = SCREEN_W / SHOT_W;
const BEZEL = PHONE_W * 0.026;

const MessagesIcon: React.FC = () => (
  <div
    style={{
      width: 92,
      height: 92,
      borderRadius: 22,
      background: 'linear-gradient(180deg, #6CF27F 0%, #0CC143 100%)',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
    }}
  >
    <svg width="58" height="58" viewBox="0 0 24 24">
      <path
        fill="#fff"
        d="M12 3.5c-5 0-9 3.3-9 7.4 0 2.3 1.3 4.4 3.3 5.7-.2 1.3-.9 2.6-2 3.4 2 .1 3.8-.6 5-1.7.9.2 1.8.3 2.7.3 5 0 9-3.3 9-7.4S17 3.5 12 3.5z"
      />
    </svg>
  </div>
);

const ShortcutsIcon: React.FC = () => (
  <div
    style={{
      width: 92,
      height: 92,
      borderRadius: 22,
      background: 'linear-gradient(135deg, #FF5F8F 0%, #9A5CF5 52%, #2D8CFF 100%)',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      position: 'relative',
    }}
  >
    <div style={{position: 'absolute', width: 34, height: 34, borderRadius: 9, background: 'rgba(255,255,255,0.55)', transform: 'translate(-9px, -9px) rotate(45deg)'}} />
    <div style={{position: 'absolute', width: 34, height: 34, borderRadius: 9, background: '#fff', transform: 'translate(9px, 9px) rotate(45deg)'}} />
  </div>
);

/** iOS 通知横幅 */
const Banner: React.FC<{icon: React.ReactNode; title: string; time?: string; children: React.ReactNode; style?: React.CSSProperties}> = ({
  icon,
  title,
  time = '现在',
  children,
  style,
}) => (
  <div
    style={{
      position: 'absolute',
      left: 80,
      width: 920,
      padding: '26px 30px',
      boxSizing: 'border-box',
      borderRadius: 48,
      background: 'rgba(248,248,250,0.93)',
      backdropFilter: 'blur(30px)',
      WebkitBackdropFilter: 'blur(30px)',
      boxShadow: '0 30px 80px rgba(0,0,0,0.45)',
      display: 'flex',
      gap: 26,
      alignItems: 'center',
      fontFamily: FONT,
      color: '#111',
      ...style,
    }}
  >
    {icon}
    <div style={{flex: 1, minWidth: 0}}>
      <div style={{display: 'flex', justifyContent: 'space-between', alignItems: 'baseline'}}>
        <span style={{fontSize: 34, fontWeight: 600}}>{title}</span>
        <span style={{fontSize: 27, color: '#8a8a8e'}}>{time}</span>
      </div>
      <div style={{fontSize: 31, lineHeight: 1.32, marginTop: 4, color: '#222'}}>{children}</div>
    </div>
  </div>
);

/** 4–13s：收到扣款短信 → 快捷指令自动运行 → 账单页插入新的一笔 */
export const Shortcut: React.FC = () => {
  const frame = useCurrentFrame();

  const phoneIn = springIn(frame, 0, 22);

  // 通知横幅
  const smsIn = pop(frame, 34);
  const runIn = pop(frame, 76);
  const done = frame >= 112;
  const doneP = pop(frame, 112);
  const bannersOut = easeInOut(frame, 148, 164);

  // 插入动画：列表下移一行，新行从顶部出现
  const insert = easeInOut(frame, 160, 182);
  const statsSwap = lin(frame, 166, 180);
  const glow = frame < 182 ? 0 : 0.55 + 0.45 * Math.sin((frame - 182) / 7);
  const glowIn = ease(frame, 178, 190);

  const screenTop = PHONE_TOP + BEZEL;
  const rowScreenTop = screenTop + BILL.rowTop * K;

  return (
    <AbsoluteFill>
      <Background accent={C.green} glowY={0.55} />
      <Headline index="01" kicker="快捷指令 · 自动记账" lines={['收到扣款短信', <><Hl>自动</Hl>记一笔</>]} />

      <div
        style={{
          position: 'absolute',
          left: (1080 - PHONE_W) / 2,
          top: PHONE_TOP + (1 - phoneIn) * 240,
          opacity: phoneIn,
        }}
      >
        <Phone width={PHONE_W}>
          {/* 底：记账前 */}
          <Shot src="screens/bill_before.png" />
          {/* 列表区：记账后的截图上移一行起步，下滑归位 = 新的一笔被插进来 */}
          <div
            style={{
              position: 'absolute',
              left: 0,
              right: 0,
              top: BILL.listTop * K,
              bottom: 0,
              overflow: 'hidden',
              background: C.iosBg,
            }}
          >
            <Shot
              src="screens/bill_after.png"
              style={{top: -BILL.listTop * K - (1 - insert) * BILL.rowPitch * K}}
            />
          </div>
          {/* 统计数字：前后交叉淡化 */}
          <ShotCrop
            src="screens/bill_after.png"
            scale={K}
            cropTop={BILL.statsTop}
            cropHeight={BILL.statsBottom - BILL.statsTop}
            style={{opacity: statsSwap}}
          />
          {/* 底部 Tab 栏保持不动 */}
          <ShotCrop src="screens/bill_before.png" scale={K} cropTop={BILL.tabBarTop} cropHeight={2868 - BILL.tabBarTop} />
          {/* 新行高亮 */}
          <div
            style={{
              position: 'absolute',
              left: BILL.rowLeft * K - 4,
              top: BILL.rowTop * K - 4,
              width: (BILL.rowRight - BILL.rowLeft) * K + 8,
              height: BILL.rowHeight * K + 8,
              borderRadius: 34,
              border: `4px solid ${C.gold}`,
              opacity: glowIn,
              boxShadow: `0 0 ${24 + glow * 26}px ${C.gold}AA`,
            }}
          />
        </Phone>
      </div>

      {/* 通知横幅 */}
      <div style={{opacity: 1 - bannersOut, transform: `translateY(${-bannersOut * 120}px)`}}>
        <Banner
          icon={<MessagesIcon />}
          title="银行提醒"
          style={{top: 600 + (1 - smsIn) * -260, opacity: Math.min(1, smsIn * 1.4)}}
        >
          Your card ending in 7731 was charged $6.75 at BLUE BOTTLE COFFEE.
        </Banner>
        <Banner
          icon={<ShortcutsIcon />}
          title="快捷指令"
          style={{top: 830 + (1 - runIn) * -120, opacity: Math.min(1, runIn * 1.4), transform: `scale(${0.94 + runIn * 0.06})`}}
        >
          {done ? (
            <span style={{display: 'inline-flex', alignItems: 'center', gap: 10, opacity: doneP}}>
              <IconCheck size={34} color="#14A44D" strokeWidth={3} />
              已成功添加账单：Blue Bottle Coffee – $6.75
            </span>
          ) : (
            <span style={{display: 'inline-flex', alignItems: 'center', gap: 14}}>
              <Spinner size={34} frame={frame} />
              正在运行「短信记账」…
            </span>
          )}
        </Banner>
      </div>

      {/* 插入完成后的说明 */}
      <div
        style={{
          position: 'absolute',
          top: rowScreenTop + 210, // 压在下面几行上，不挡新插入的那一行
          left: 0,
          right: 0,
          display: 'flex',
          justifyContent: 'center',
          opacity: springIn(frame, 188),
          transform: `translateY(${(1 - springIn(frame, 188)) * 24}px)`,
        }}
      >
        <Chip tone="gold" size={36} icon={<IconCheck size={36} strokeWidth={3} />}>
          尾号匹配卡片 · 返现自动算好
        </Chip>
      </div>
      <div
        style={{
          position: 'absolute',
          top: rowScreenTop + 318,
          left: 0,
          right: 0,
          display: 'flex',
          justifyContent: 'center',
          opacity: springIn(frame, 206),
          transform: `translateY(${(1 - springIn(frame, 206)) * 24}px)`,
        }}
      >
        <Chip size={32} icon={<IconPhone size={34} />}>
          也支持：操作按钮一键截屏记账
        </Chip>
      </div>
    </AbsoluteFill>
  );
};
