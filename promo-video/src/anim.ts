import {Easing, interpolate, spring} from 'remotion';
import {FPS} from './theme';

const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;

/** 从 start 帧开始的弹簧进度 0→1（无回弹） */
export const springIn = (frame: number, start: number, durationInFrames = 18) =>
  spring({frame: frame - start, fps: FPS, config: {damping: 200}, durationInFrames});

/** 带一点回弹的进度，给卡片、气泡用 */
export const pop = (frame: number, start: number) =>
  spring({frame: frame - start, fps: FPS, config: {damping: 14, stiffness: 170}});

/** 区间映射并夹紧，easeOut */
export const ease = (frame: number, from: number, to: number, out: [number, number] = [0, 1]) =>
  interpolate(frame, [from, to], out, {...clamp, easing: Easing.out(Easing.cubic)});

export const easeInOut = (frame: number, from: number, to: number, out: [number, number] = [0, 1]) =>
  interpolate(frame, [from, to], out, {...clamp, easing: Easing.inOut(Easing.cubic)});

export const lin = (frame: number, from: number, to: number, out: [number, number] = [0, 1]) =>
  interpolate(frame, [from, to], out, clamp);
