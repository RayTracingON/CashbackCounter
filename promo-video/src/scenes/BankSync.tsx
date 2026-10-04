import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {ease, easeInOut, lin, pop, springIn} from '../anim';
import {Background} from '../components/Background';
import {Chip} from '../components/Chip';
import {Headline, Hl} from '../components/Headline';
import {IconBell, IconLock, IconRefund} from '../components/Icons';
import {Phone, screenWidthOf, ShotCrop} from '../components/Phone';
import {Spinner} from '../components/Spinner';
import {BILL, C, FONT, SHOT_W} from '../theme';

const PHONE_W = 780;
const PHONE_TOP = 640;
const SCREEN_W = screenWidthOf(PHONE_W);
const K = SCREEN_W / SHOT_W;
const PT = SCREEN_W / 440; // iOS 逻辑点 → 视频像素

type Account = {title: string; linked: string; toggleAt: number};
const GROUPS: {name: string; unlink: string; accounts: Account[]}[] = [
  {
    name: 'Chase',
    unlink: '解绑 Chase',
    accounts: [
      {title: 'Sapphire Reserve ···4417', linked: '已关联「Chase 4417」', toggleAt: 30},
      {title: 'Freedom Flex ···2290', linked: '已关联「Chase 2290」', toggleAt: 40},
    ],
  },
  {
    name: 'American Express',
    unlink: '解绑 American Express',
    accounts: [
      {title: 'Gold Card ···1008', linked: '已关联「AMEX US 1008」', toggleAt: 50},
      {title: 'Platinum Card ···3005', linked: '已关联「AMEX US 3005」', toggleAt: 60},
    ],
  },
];

/** iOS 26 开关 */
const Toggle: React.FC<{on: number}> = ({on}) => (
  <div
    style={{
      width: 62,
      height: 28,
      borderRadius: 14,
      background: on > 0.5 ? '#34C759' : '#E3E3E8',
      position: 'relative',
      flexShrink: 0,
    }}
  >
    <div
      style={{
        position: 'absolute',
        top: 2,
        left: 2 + on * 22,
        width: 36,
        height: 24,
        borderRadius: 12,
        background: '#fff',
        boxShadow: '0 1px 4px rgba(0,0,0,0.2)',
      }}
    />
  </div>
);

/** 照着 BankSyncView 的结构重画：截图拿不到（模拟器上无法用 Apple 登录） */
const BankSyncScreen: React.FC<{frame: number}> = ({frame}) => (
  <div
    style={{
      position: 'absolute',
      top: 0,
      left: 0,
      width: 440,
      height: 956,
      transform: `scale(${PT})`,
      transformOrigin: 'top left',
      background: C.iosBg,
      fontFamily: FONT,
      color: '#000',
    }}
  >
    {/* 状态栏直接取真截图 */}
    <ShotCrop src="screens/bill_after.png" scale={1 / 3} cropTop={0} cropHeight={150} />
    {/* 导航栏 */}
    <div
      style={{
        position: 'absolute',
        top: 62,
        left: 16,
        width: 46,
        height: 46,
        borderRadius: 23,
        background: 'rgba(255,255,255,0.9)',
        boxShadow: '0 1px 6px rgba(0,0,0,0.08)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#000" strokeWidth="2.6" strokeLinecap="round">
        <path d="M15 5l-7 7 7 7" />
      </svg>
    </div>
    <div style={{position: 'absolute', top: 73, left: 0, right: 0, textAlign: 'center', fontSize: 17, fontWeight: 600}}>
      银行同步
    </div>

    <div style={{position: 'absolute', top: 128, left: 20, right: 20}}>
      {GROUPS.map((g) => (
        <div key={g.name} style={{marginBottom: 22}}>
          <div style={{fontSize: 15, fontWeight: 600, color: '#6D6D72', margin: '0 0 8px 20px'}}>{g.name}</div>
          <div style={{background: '#fff', borderRadius: 26, overflow: 'hidden'}}>
            {g.accounts.map((a, i) => {
              const on = ease(frame, a.toggleAt, a.toggleAt + 6);
              const syncing = frame >= a.toggleAt + 4 && frame < a.toggleAt + 26;
              const synced = frame >= a.toggleAt + 26;
              return (
                <div key={a.title} style={{padding: '11px 20px', position: 'relative'}}>
                  <div style={{display: 'flex', alignItems: 'center'}}>
                    <div style={{flex: 1}}>
                      <div style={{fontSize: 17}}>{a.title}</div>
                      <div style={{fontSize: 12, color: C.iosGray, marginTop: 2}}>{a.linked}</div>
                    </div>
                    <Toggle on={on} />
                  </div>
                  <div style={{fontSize: 11, color: C.iosGray, marginTop: 6, display: 'flex', alignItems: 'center', gap: 5, height: 14}}>
                    {syncing ? (
                      <>
                        <Spinner size={12} frame={frame} />
                        正在同步…
                      </>
                    ) : synced ? (
                      '上次同步 刚刚'
                    ) : (
                      '尚未同步'
                    )}
                  </div>
                  {i < g.accounts.length - 1 ? (
                    <div style={{position: 'absolute', left: 20, right: 0, bottom: 0, height: 0.5, background: '#D9D9DE'}} />
                  ) : null}
                </div>
              );
            })}
          </div>
          <div style={{display: 'flex', justifyContent: 'space-between', margin: '8px 20px 0', fontSize: 12}}>
            <span style={{color: C.iosBlue}}>管理已连接的账户</span>
            <span style={{color: '#FF3B30'}}>{g.unlink}</span>
          </div>
        </div>
      ))}
      <div
        style={{
          background: '#fff',
          borderRadius: 26,
          padding: '15px 20px',
          display: 'flex',
          alignItems: 'center',
          gap: 10,
          color: C.iosBlue,
          fontSize: 17,
        }}
      >
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke={C.iosBlue} strokeWidth="2">
          <circle cx="12" cy="12" r="9" />
          <path d="M12 8v8M8 12h8" strokeLinecap="round" />
        </svg>
        添加银行
      </div>
      <div style={{fontSize: 12, color: C.iosGray, margin: '8px 20px 0', lineHeight: 1.45, whiteSpace: 'pre-line'}}>
        {'绑定前需要用 Face ID 验证身份。\n我们拿不到完整卡号 —— Plaid 的任何产品都不提供。'}
      </div>
    </div>
  </div>
);

/** 账单页：交易从银行一条条落进来（用记账前的截图，前 5 行全是银行同步卡） */
const BillStream: React.FC<{frame: number}> = ({frame}) => {
  const refresh = frame < 18;
  return (
    <>
      <ShotCrop src="screens/bill_before.png" scale={K} cropTop={0} cropHeight={BILL.listTop} />
      {refresh ? (
        <div
          style={{
            position: 'absolute',
            top: (BILL.listTop + 40) * K,
            left: 0,
            right: 0,
            display: 'flex',
            justifyContent: 'center',
          }}
        >
          <Spinner size={44} frame={frame} />
        </div>
      ) : null}
      {[0, 1, 2, 3, 4, 5].map((i) => {
        const start = 14 + i * 7;
        const p = pop(frame, start);
        const top = BILL.rowTop + i * BILL.rowPitch - 20;
        return (
          <ShotCrop
            key={i}
            src="screens/bill_before.png"
            scale={K}
            cropTop={top}
            cropHeight={BILL.rowPitch}
            style={{
              opacity: lin(frame, start, start + 6),
              transform: `translateY(${(1 - p) * -60}px)`,
            }}
          />
        );
      })}
      <ShotCrop src="screens/bill_before.png" scale={K} cropTop={BILL.tabBarTop} cropHeight={2868 - BILL.tabBarTop} />
    </>
  );
};

/** 13–21s：银行同步 */
export const BankSync: React.FC = () => {
  const frame = useCurrentFrame();
  const phoneIn = springIn(frame, 0, 22);
  const SWITCH = 112;
  const sw = easeInOut(frame, SWITCH, SWITCH + 16);

  const chips = [
    {icon: <IconLock size={36} />, text: 'Plaid 银行级安全连接', at: 150, side: -1, top: 1330},
    {icon: <IconRefund size={36} />, text: '退款自动抵销返现', at: 164, side: 1, top: 1440},
    {icon: <IconBell size={36} />, text: '新交易即时推送', at: 178, side: -1, top: 1550},
  ];

  return (
    <AbsoluteFill>
      <Background accent="#3BA7FF" glowY={0.55} />
      <Headline
        index="02"
        kicker="美国银行同步"
        lines={['绑定一次银行', <>交易<Hl>自己进来</Hl></>]}
      />

      <div
        style={{
          position: 'absolute',
          left: (1080 - PHONE_W) / 2,
          top: PHONE_TOP + (1 - phoneIn) * 240,
          opacity: phoneIn,
        }}
      >
        <Phone width={PHONE_W}>
          <div style={{position: 'absolute', inset: 0, transform: `translateX(${-sw * 30}%)`, opacity: 1 - sw * 0.6}}>
            <BankSyncScreen frame={frame} />
          </div>
          <div
            style={{
              position: 'absolute',
              inset: 0,
              transform: `translateX(${(1 - sw) * 100}%)`,
              boxShadow: '-20px 0 40px rgba(0,0,0,0.15)',
              background: C.iosBg,
            }}
          >
            {frame >= SWITCH ? <BillStream frame={frame - SWITCH} /> : null}
          </div>
        </Phone>
      </div>

      {chips.map((c) => {
        const p = springIn(frame, c.at, 16);
        return (
          <div
            key={c.text}
            style={{
              position: 'absolute',
              top: c.top,
              left: c.side < 0 ? 60 : undefined,
              right: c.side > 0 ? 60 : undefined,
              opacity: p,
              transform: `translateX(${(1 - p) * 120 * c.side}px)`,
            }}
          >
            <Chip icon={c.icon} size={36}>
              {c.text}
            </Chip>
          </div>
        );
      })}
    </AbsoluteFill>
  );
};
