import React from 'react';
import {linearTiming, TransitionSeries} from '@remotion/transitions';
import {fade} from '@remotion/transitions/fade';
import {slide} from '@remotion/transitions/slide';
import {AbsoluteFill} from 'remotion';
import {AI} from './scenes/AI';
import {BankSync} from './scenes/BankSync';
import {Hook} from './scenes/Hook';
import {Outro} from './scenes/Outro';
import {Shortcut} from './scenes/Shortcut';
import {Templates} from './scenes/Templates';

const T = 12; // 转场帧数，相邻两段重叠

// 每段时长已经把转场重叠算进去：总长 = Σ时长 − 5×T = 1200 帧 = 40s
const SCENES = [
  {C: Hook, d: 132},
  {C: Shortcut, d: 282},
  {C: BankSync, d: 252},
  {C: AI, d: 282},
  {C: Templates, d: 192},
  {C: Outro, d: 120},
];

export const PROMO_DURATION = SCENES.reduce((s, x) => s + x.d, 0) - (SCENES.length - 1) * T;

export const Promo: React.FC = () => (
  <AbsoluteFill style={{background: '#03100B'}}>
    <TransitionSeries>
      {SCENES.flatMap(({C, d}, i) => {
        const seq = (
          <TransitionSeries.Sequence key={`s${i}`} durationInFrames={d} premountFor={30}>
            <C />
          </TransitionSeries.Sequence>
        );
        if (i === SCENES.length - 1) return [seq];
        // 功能段之间横推，首尾用淡入淡出
        const presentation = i === 0 || i === SCENES.length - 2 ? fade() : slide({direction: 'from-right'});
        return [
          seq,
          <TransitionSeries.Transition key={`t${i}`} presentation={presentation} timing={linearTiming({durationInFrames: T})} />,
        ];
      })}
    </TransitionSeries>
  </AbsoluteFill>
);
