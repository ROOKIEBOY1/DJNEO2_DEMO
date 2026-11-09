const {test}=require('node:test');const assert=require('node:assert/strict');
const {CloseupMediaGroup}=require('../entry/src/main/ets/core/media/CloseupMediaGroup.ets');

test('unowned groups stay independent and do not prefill the next closeup',()=>{
  const group=new CloseupMediaGroup();
  assert.equal(group.owns(10,2),false);
  assert.deepEqual(group.add(['old','old'],10,2),['old']);
  group.begin(10,2);assert.equal(group.owns(10,2),true);
  assert.deepEqual(group.add([],10,2),[]);
});

test('late clips append to the owned closeup in order without losing first-step videos',()=>{
  const group=new CloseupMediaGroup();group.begin(10,2);
  assert.deepEqual(group.add(['dolly-a','dolly-b'],10,2),['dolly-a','dolly-b']);
  assert.deepEqual(group.add(['circle-a'],10,2),['dolly-a','dolly-b','circle-a']);
  assert.deepEqual(group.add(['circle-a','dolly-b','circle-b'],10,2),['dolly-a','dolly-b','circle-a','circle-b']);
});

test('input and returned arrays cannot mutate the stored clip group',()=>{
  const group=new CloseupMediaGroup();group.begin(10,2);const input=['a'];
  const result=group.add(input,10,2);input.push('changed');result.push('also-changed');
  assert.deepEqual(group.add([],10,2),['a']);
});

test('other sessions and flight generations return independent clips without contaminating ownership',()=>{
  const group=new CloseupMediaGroup();group.begin(10,2);group.add(['first'],10,2);
  for(const [session,generation] of [[11,2],[10,3]]){
    assert.equal(group.owns(session,generation),false);
    const outside=group.add(['outside','outside'],session,generation);
    assert.deepEqual(outside,['outside']);outside.push('mutated');
  }
  assert.equal(group.owns(10,2),true);assert.deepEqual(group.add([],10,2),['first']);
});

test('clear rejects late old groups and a new begin starts with only its own clips',()=>{
  const group=new CloseupMediaGroup();group.begin(10,2);group.add(['old'],10,2);group.clear();
  assert.equal(group.owns(10,2),false);
  assert.deepEqual(group.add(['late'],10,2),['late']);
  group.begin(11,3);assert.deepEqual(group.add(['new'],11,3),['new']);
  assert.deepEqual(group.add(['late-old'],10,2),['late-old']);
  assert.deepEqual(group.add([],11,3),['new']);
  group.begin(11,3);assert.deepEqual(group.add([],11,3),[]);
});
