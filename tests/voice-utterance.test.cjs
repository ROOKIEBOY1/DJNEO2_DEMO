const {test}=require('node:test');const assert=require('node:assert/strict');
const {normalizeDroneUtterance}=require('../entry/src/main/ets/core/domain/VoiceUtterance.ets');
const {parseDirectFlightVoice}=require('../entry/src/main/ets/core/domain/AgentAction.ets');
test('known Hitchcock ASR aliases are corrected only in a filming or camera-movement context',()=>{
  assert.equal(normalizeDroneUtterance('给黑色衣服的男生拍一个戏曲QQ运镜。'),'给黑色衣服的男生拍一个希区柯克运镜。');
  assert.equal(normalizeDroneUtterance('给白衣男生拍三倍半身西区科克镜头'),'给白衣男生拍三倍半身希区柯克镜头');
  assert.equal(normalizeDroneUtterance('给黑衣男生拍个戏曲ＱＱ运镜'),'给黑衣男生拍个希区柯克运镜');
  for(const text of ['选黑色衣服的人','拍一张照片','拍戏曲节目','戏曲QQ','希区柯克运镜'])assert.equal(normalizeDroneUtterance(text),text);
});
test('normalization preserves negation, questions and subject descriptions and never becomes a direct takeoff',()=>{
  const negative=normalizeDroneUtterance('不要给白色衣服的女生拍戏曲QQ运镜');
  assert.equal(negative,'不要给白色衣服的女生拍希区柯克运镜');
  const question=normalizeDroneUtterance('可以给男生拍戏曲QQ运镜吗？');
  assert.equal(question,'可以给男生拍希区柯克运镜吗？');
  assert.equal(normalizeDroneUtterance('将西区科克运镜设置成三倍半身'),'将希区柯克运镜设置成三倍半身');
  for(const text of [negative,question,'给黑衣男生拍戏曲QQ运镜'])assert.equal(parseDirectFlightVoice(text),undefined);
});
