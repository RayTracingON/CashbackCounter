import React from 'react';
/** iOS 风格菊花转圈，按帧旋转（不能用 CSS 动画） */
export const Spinner: React.FC<{size?: number; frame: number; color?: string}> = ({size = 32, frame, color = '#8a8a8e'}) => {
  const step = Math.floor(frame / 2) % 8;
  return (
    <svg width={size} height={size} viewBox="0 0 24 24">
      {Array.from({length: 8}).map((_, i) => {
        const opacity = 0.25 + (((i - step + 8) % 8) / 7) * 0.75;
        return (
          <rect
            key={i}
            x="11"
            y="2"
            width="2.4"
            height="6.2"
            rx="1.2"
            fill={color}
            opacity={opacity}
            transform={`rotate(${i * 45} 12 12)`}
          />
        );
      })}
    </svg>
  );
};
