import React from 'react';
import {Img, staticFile} from 'remotion';
import {SHOT_H, SHOT_W} from '../theme';

/** 外框宽度 width 的 iPhone 机身；children 按屏幕坐标绝对定位 */
export const Phone: React.FC<{
  width: number;
  children: React.ReactNode;
  style?: React.CSSProperties;
}> = ({width, children, style}) => {
  const bezel = width * 0.026;
  const screenW = width - bezel * 2;
  const screenH = (screenW * SHOT_H) / SHOT_W;
  const outerR = width * 0.155;
  return (
    <div
      style={{
        width,
        height: screenH + bezel * 2,
        borderRadius: outerR,
        padding: bezel,
        boxSizing: 'border-box',
        position: 'relative',
        background: 'linear-gradient(145deg, #4a4e52 0%, #1b1d1f 30%, #2c2f32 65%, #0d0e0f 100%)',
        boxShadow:
          'inset 0 0 0 2px rgba(255,255,255,0.10), 0 0 0 1.5px rgba(0,0,0,0.9), 0 50px 120px rgba(0,0,0,0.6), 0 0 80px rgba(52,199,123,0.12)',
        ...style,
      }}
    >
      <div
        style={{
          width: screenW,
          height: screenH,
          borderRadius: outerR - bezel,
          overflow: 'hidden',
          position: 'relative',
          background: '#F2F2F7',
        }}
      >
        {children}
        {/* 灵动岛：截图里没有，按真机比例补上 */}
        <div
          style={{
            position: 'absolute',
            top: screenW * 0.0326,
            left: '50%',
            transform: 'translateX(-50%)',
            width: screenW * 0.213,
            height: screenW * 0.0814,
            borderRadius: screenW,
            background: '#000',
          }}
        />
      </div>
    </div>
  );
};

/** 屏幕内宽度 = 外框宽度扣掉两侧边框 */
export const screenWidthOf = (phoneWidth: number) => phoneWidth - phoneWidth * 0.026 * 2;

/** 铺满屏幕的整张截图 */
export const Shot: React.FC<{src: string; style?: React.CSSProperties}> = ({src, style}) => (
  <Img
    src={staticFile(src)}
    style={{position: 'absolute', top: 0, left: 0, width: '100%', display: 'block', ...style}}
  />
);

/**
 * 截图的一块矩形区域（像素坐标，原图 1320 宽），按 scale 缩放后放回同样的屏幕位置。
 * 用来把账单行、统计框单独抠出来做动画。
 */
export const ShotCrop: React.FC<{
  src: string;
  scale: number;
  cropTop: number;
  cropHeight: number;
  cropLeft?: number;
  cropWidth?: number;
  style?: React.CSSProperties;
}> = ({src, scale, cropTop, cropHeight, cropLeft = 0, cropWidth = SHOT_W, style}) => (
  <div
    style={{
      position: 'absolute',
      left: cropLeft * scale,
      top: cropTop * scale,
      width: cropWidth * scale,
      height: cropHeight * scale,
      overflow: 'hidden',
      ...style,
    }}
  >
    <Img
      src={staticFile(src)}
      style={{
        position: 'absolute',
        left: -cropLeft * scale,
        top: -cropTop * scale,
        width: SHOT_W * scale,
        display: 'block',
      }}
    />
  </div>
);
