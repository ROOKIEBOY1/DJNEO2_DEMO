// Correct complete known ASR aliases only. The model still decides intent, including negation and questions.
export function normalizeDroneUtterance(text: string): string {
  if (!/拍|运镜|镜头|视频|录像/.test(text)) return text;
  return text.replace(/(?:戏曲|希区|西区)\s*[QqＱｑ]\s*[QqＱｑ]/g, '希区柯克')
    .replace(/西区柯克|西区科克|希区科克/g, '希区柯克');
}
