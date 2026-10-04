import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {ease, easeInOut, lin, pop, springIn} from '../anim';
import {Background} from '../components/Background';
import {Chip} from '../components/Chip';
import {Headline, Hl} from '../components/Headline';
import {IconChip, IconCloud, IconKey, IconLock, IconRefresh, IconSparkle} from '../components/Icons';
import {C, FONT, MONO} from '../theme';

// 演示用的虚构小票：金额自洽（27.00 + 2.40 = 29.40）
const RECEIPT_LINES: {l: string; r?: string; bold?: boolean; center?: boolean; big?: boolean}[] = [
  {l: 'GREENLEAF CAFE', center: true, bold: true, big: true},
  {l: '214 Bedford Ave, Brooklyn NY', center: true},
  {l: '10/04/2026            9:12 AM'},
  {l: '--------------------------------'},
  {l: 'Avocado Toast', r: '12.50'},
  {l: 'Oat Latte', r: '5.75'},
  {l: 'Butter Croissant', r: '4.25'},
  {l: 'Fresh Orange Juice', r: '4.50'},
  {l: '--------------------------------'},
  {l: 'SUBTOTAL', r: '27.00'},
  {l: 'TAX', r: '2.40'},
  {l: 'TOTAL  USD', r: '29.40', bold: true, big: true},
  {l: 'VISA  **** **** **** 4417'},
  {l: 'THANK YOU!', center: true},
];

const Receipt: React.FC<{scanY: number; highlight: (i: number) => number}> = ({scanY, highlight}) => (
  <div
    style={{
      width: 560,
      padding: '44px 40px 60px',
      boxSizing: 'border-box',
      background: '#FBFAF6',
      fontFamily: MONO,
      color: '#2a2a2a',
      fontSize: 25,
      lineHeight: 1.65,
      position: 'relative',
      boxShadow: '0 40px 90px rgba(0,0,0,0.5)',
      // 锯齿底边
      clipPath:
        'polygon(0 0,100% 0,100% 97%,95% 100%,90% 97%,85% 100%,80% 97%,75% 100%,70% 97%,65% 100%,60% 97%,55% 100%,50% 97%,45% 100%,40% 97%,35% 100%,30% 97%,25% 100%,20% 97%,15% 100%,10% 97%,5% 100%,0 97%)',
    }}
  >
    {RECEIPT_LINES.map((line, i) => (
      <div
        key={i}
        style={{
          display: 'flex',
          justifyContent: line.center ? 'center' : 'space-between',
          fontWeight: line.bold ? 700 : 400,
          fontSize: line.big ? 30 : 25,
          background: `rgba(52,199,123,${highlight(i) * 0.22})`,
          borderRadius: 6,
          margin: '0 -8px',
          padding: '0 8px',
          whiteSpace: 'pre',
        }}
      >
        <span>{line.l}</span>
        {line.r ? <span>{line.r}</span> : null}
      </div>
    ))}
    {/* 扫描光束 */}
    <div
      style={{
        position: 'absolute',
        left: 0,
        right: 0,
        top: `${scanY * 100}%`,
        height: 6,
        background: C.mint,
        boxShadow: `0 0 30px 12px ${C.mint}99`,
        opacity: scanY > 0 && scanY < 1 ? 1 : 0,
      }}
    />
  </div>
);

const FIELDS: {k: string; v: string; note?: string; gold?: boolean}[] = [
  {k: '商户', v: 'Greenleaf Cafe'},
  {k: '金额', v: '$29.40'},
  {k: '类别', v: '餐饮美食'},
  {k: '日期', v: '2026-10-04'},
  {k: '卡片', v: 'Sapphire Reserve', note: '按尾号 4417 自动匹配'},
  {k: '积分', v: '+88 UR ≈ $1.76', gold: true},
];

const ResultCard: React.FC<{frame: number; start: number}> = ({frame, start}) => (
  <div
    style={{
      width: 560,
      padding: '30px 34px',
      boxSizing: 'border-box',
      borderRadius: 40,
      background: 'rgba(255,255,255,0.97)',
      boxShadow: '0 40px 90px rgba(0,0,0,0.45)',
      fontFamily: FONT,
      color: '#111',
    }}
  >
    <div style={{display: 'flex', alignItems: 'center', gap: 12, fontSize: 32, fontWeight: 600, color: '#14A44D', marginBottom: 14}}>
      <IconSparkle size={36} color="#14A44D" />
      识别完成
    </div>
    {FIELDS.map((f, i) => {
      const p = springIn(frame, start + 6 + i * 5, 14);
      return (
        <div
          key={f.k}
          style={{
            display: 'flex',
            alignItems: 'baseline',
            justifyContent: 'space-between',
            padding: '13px 0',
            borderTop: i === 0 ? 'none' : '1.5px solid #ECECF0',
            opacity: p,
            transform: `translateX(${(1 - p) * 40}px)`,
          }}
        >
          <span style={{fontSize: 28, color: '#8a8a8e'}}>{f.k}</span>
          <span style={{textAlign: 'right'}}>
            <span style={{fontSize: 32, fontWeight: 600, color: f.gold ? '#B07A00' : '#111'}}>{f.v}</span>
            {f.note ? <div style={{fontSize: 21, color: '#14A44D', marginTop: 2}}>{f.note}</div> : null}
          </span>
        </div>
      );
    })}
  </div>
);

const MODELS = [
  {icon: <IconChip size={56} />, tint: C.mint, title: '端侧模型', desc: 'Apple 端侧大模型 · 完全离线'},
  {icon: <IconLock size={56} />, tint: C.gold, title: 'Apple 私有云计算', desc: '端到端加密 · 开发者也看不到'},
  {icon: <IconKey size={56} />, tint: '#C59BFF', title: '自定义 API', desc: '兼容 OpenAI / Anthropic / Gemini'},
];

/** 21–30s：小票识别 + 三种 AI 通道 */
export const AI: React.FC = () => {
  const frame = useCurrentFrame();
  const PHASE2 = 150;

  const receiptIn = pop(frame, 6);
  const scanY = lin(frame, 26, 76);
  const toSide = easeInOut(frame, 82, 104);
  const phase1Out = easeInOut(frame, PHASE2 - 6, PHASE2 + 8);
  const lineCount = RECEIPT_LINES.length;
  const highlight = (i: number) => {
    const passed = scanY * (lineCount + 1) - i;
    return frame > 104 ? 0 : Math.max(0, Math.min(1, passed)) * (1 - lin(frame, 90, 104));
  };

  const head1 = 1 - lin(frame, PHASE2 - 8, PHASE2);
  const head2 = frame >= PHASE2 - 2;

  // 三个通道卡片之间轮流高亮
  const active = frame < 196 ? 0 : frame < 226 ? 1 : 2;

  return (
    <AbsoluteFill>
      <Background accent={C.mint} glowY={0.5} />

      {/* 标题：前半段讲识别，后半段讲选模型 */}
      <div style={{opacity: head1}}>
        <Headline index="03" kicker="端侧 + 云端 AI" lines={['拍张小票', <><Hl>AI</Hl> 秒填好</>]} />
      </div>
      {head2 ? (
        <Headline index="03" kicker="端侧 + 云端 AI" lines={['离线还是云端', <><Hl>你来选</Hl></>]} start={PHASE2 - 2} />
      ) : null}

      {/* 第一段：小票 → 结果卡 */}
      <div style={{opacity: 1 - phase1Out, transform: `translateY(${-phase1Out * 80}px)`}}>
        <div
          style={{
            position: 'absolute',
            left: 540 - 280 + toSide * -235,
            top: 650 + (1 - receiptIn) * 500,
            transform: `rotate(${-3 + toSide * -2}deg) scale(${1 - toSide * 0.24})`,
            transformOrigin: 'top center',
            opacity: Math.min(1, receiptIn * 1.4),
          }}
        >
          <Receipt scanY={scanY} highlight={highlight} />
        </div>
        <div
          style={{
            position: 'absolute',
            left: 470,
            top: 700,
            opacity: lin(frame, 92, 102),
            transform: `translateX(${(1 - ease(frame, 92, 110)) * 120}px)`,
          }}
        >
          <ResultCard frame={frame} start={96} />
        </div>
      </div>

      {/* 第二段：三种模型通道 */}
      {frame >= PHASE2 - 4
        ? MODELS.map((m, i) => {
            const p = pop(frame, PHASE2 + 4 + i * 8);
            const on = i === active ? ease(frame, [180, 196, 226][i], [180, 196, 226][i] + 8) : 0;
            return (
              <div
                key={m.title}
                style={{
                  position: 'absolute',
                  left: 90,
                  width: 900,
                  top: 680 + i * 230,
                  height: 196,
                  boxSizing: 'border-box',
                  padding: '0 40px',
                  borderRadius: 44,
                  display: 'flex',
                  alignItems: 'center',
                  gap: 34,
                  background: `rgba(14,38,29,${0.78 + on * 0.1})`,
                  border: `2px solid ${on > 0 ? m.tint : 'rgba(255,255,255,0.14)'}`,
                  boxShadow: `0 24px 60px rgba(0,0,0,0.4), 0 0 ${on * 50}px ${m.tint}66`,
                  backdropFilter: 'blur(20px)',
                  opacity: Math.min(1, p * 1.3),
                  transform: `translateY(${(1 - p) * 80}px) scale(${1 + on * 0.025})`,
                  fontFamily: FONT,
                }}
              >
                <div
                  style={{
                    width: 116,
                    height: 116,
                    borderRadius: 30,
                    background: `${m.tint}22`,
                    border: `2px solid ${m.tint}66`,
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    color: m.tint,
                    flexShrink: 0,
                  }}
                >
                  {m.icon}
                </div>
                <div>
                  <div style={{fontSize: 50, fontWeight: 600, color: C.white, letterSpacing: 1}}>{m.title}</div>
                  <div style={{fontSize: 33, color: C.dim, marginTop: 6}}>{m.desc}</div>
                </div>
                {i === 1 ? (
                  <div style={{marginLeft: 'auto', color: C.gold, opacity: 0.9}}>
                    <IconCloud size={48} />
                  </div>
                ) : null}
              </div>
            );
          })
        : null}

      {frame >= PHASE2 ? (
        <div
          style={{
            position: 'absolute',
            top: 1400,
            left: 0,
            right: 0,
            display: 'flex',
            justifyContent: 'center',
            opacity: springIn(frame, PHASE2 + 40),
            transform: `translateY(${(1 - springIn(frame, PHASE2 + 40)) * 24}px)`,
          }}
        >
          <Chip tone="mint" size={34} icon={<IconRefresh size={36} />}>
            云端不可用时，自动回退端侧
          </Chip>
        </div>
      ) : null}
    </AbsoluteFill>
  );
};
