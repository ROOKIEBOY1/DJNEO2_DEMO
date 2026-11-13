const {test}=require('node:test');
const assert=require('node:assert/strict');
const path=require('node:path');
const source=path.resolve(__dirname,'../entry/src/main/ets/core/domain/AutoSubjectSearch.ets');
  const {AutoSubjectSearch}=require(source);
  function deferred(){let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};}
  function fixture(results=[{status:'found',subjectId:13}],overrides={}){
    let now=1000,current=true,index=0;const calls=[],updates=[];
    const search=new AutoSubjectSearch(()=>updates.push(search.snapshot()),()=>now);
    const port={isCurrent:()=>current,
      settle:async deadline=>{calls.push(['settle',deadline]);},
      inspect:async deadline=>{calls.push(['inspect',deadline]);return results[index++];},
      turn:async(seconds,deadline)=>{calls.push(['turn',seconds,deadline]);},...overrides};
    return {search,port,calls,updates,advance:ms=>{now+=ms;},invalidate:()=>{current=false;}};
  }
  test('starts with a settled current view and returns the selected subject without turning',async()=>{
    const f=fixture();assert.equal(await f.search.find(f.port),13);
    assert.deepEqual(f.calls,[['settle',121000],['inspect',121000]]);
    assert.equal(f.search.snapshot().active,false);assert.equal(f.search.snapshot().stage,'found');
    assert.ok(f.updates.some(s=>s.active&&s.stage==='inspecting'));
  });
  test('only explicit absence advances the view by two seconds before settling and inspecting again',async()=>{
    const f=fixture([{status:'not_found'},{status:'not_found'},{status:'found',subjectId:0}]);
    assert.equal(await f.search.find(f.port),0);
    assert.deepEqual(f.calls.map(c=>c[0]),['settle','inspect','turn','settle','inspect','turn','settle','inspect']);
    assert.deepEqual(f.calls.filter(c=>c[0]==='turn'),[['turn',2,121000],['turn',2,121000]]);
    assert.equal(f.search.snapshot().turns,2);
  });
  test('inspects the eighth turned view but never dispatches a ninth turn',async()=>{
    const f=fixture(Array.from({length:9},()=>({status:'not_found'})));
    await assert.rejects(f.search.find(f.port),/未找到|没有找到/);
    assert.equal(f.calls.filter(c=>c[0]==='turn').length,8);
    assert.equal(f.calls.filter(c=>c[0]==='inspect').length,9);
    assert.equal(f.search.snapshot().active,false);assert.equal(f.search.snapshot().stage,'failed');
  });
  test('may find the target in the last allowed turned view',async()=>{
    const f=fixture([...Array.from({length:8},()=>({status:'not_found'})),{status:'found',subjectId:255}]);
    assert.equal(await f.search.find(f.port),255);assert.equal(f.search.snapshot().turns,8);
  });
  test('ambiguity is rechecked once in the same direction and never permits blind turning',async()=>{
    const f=fixture([{status:'ambiguous'},{status:'ambiguous'}]);
    await assert.rejects(f.search.find(f.port),/描述|明确|歧义/);
    assert.deepEqual(f.calls.map(c=>c[0]),['settle','inspect','settle','inspect']);
  });
  test('a same-direction ambiguity recheck can select a target',async()=>{
    const f=fixture([{status:'ambiguous'},{status:'found',subjectId:4}]);
    assert.equal(await f.search.find(f.port),4);assert.equal(f.search.snapshot().turns,0);
  });
  test('absence on ambiguity recheck permits a turn and resets ambiguity allowance for a new view',async()=>{
    const f=fixture([{status:'ambiguous'},{status:'not_found'},{status:'ambiguous'},{status:'found',subjectId:4}]);
    assert.equal(await f.search.find(f.port),4);assert.equal(f.search.snapshot().turns,1);
    assert.equal(f.calls.filter(c=>c[0]==='inspect').length,4);
  });
  for(const bad of [null,undefined,{},'not_found',{status:'other'},{status:'found'},
    ...[-1,256,1.5,NaN,Infinity,'4'].map(subjectId=>({status:'found',subjectId})),
    {status:'not_found',subjectId:1},{status:'ambiguous',message:12}]){
    test(`malformed selection ${JSON.stringify(bad)} fails without a turn`,async()=>{
      const f=fixture([bad]);await assert.rejects(f.search.find(f.port));
      assert.equal(f.calls.some(c=>c[0]==='turn'),false);assert.equal(f.search.snapshot().active,false);
    });
  }
  for(const phase of ['settle','inspect','turn']){
    test(`${phase} failure exits without another movement or observation`,async()=>{
      const f=fixture([{status:'not_found'}],{[phase]:async()=>{throw new Error('offline failure');}});
      await assert.rejects(f.search.find(f.port),/offline failure/);
      assert.equal(f.search.snapshot().stage,'failed');assert.equal(f.search.snapshot().active,false);
      assert.equal(f.calls.some(c=>c[0]==='turn'),false);
    });
    test(`cancellation during ${phase} ignores a late callback and cannot affect a new search`,async()=>{
      const wait=deferred();const f=fixture([{status:'not_found'}],{[phase]:()=>wait.promise});
      const old=f.search.find(f.port);const rejection=assert.rejects(old,/取消/);
      for(let i=0;i<8;i++)await Promise.resolve();
      f.search.cancel();assert.equal(f.search.snapshot().stage,'cancelled');
      const fresh=fixture().port;assert.equal(await f.search.find(fresh),13);
      const before=f.search.snapshot();wait.resolve({status:'found',subjectId:2});await rejection;
      assert.deepEqual(f.search.snapshot(),before);
    });
    test(`state change during ${phase} discards results and performs no following step`,async()=>{
      const wait=deferred();const f=fixture([{status:'not_found'}],{[phase]:()=>wait.promise});
      const running=f.search.find(f.port);
      for(let i=0;i<8;i++)await Promise.resolve();
      f.invalidate();wait.resolve({status:'found',subjectId:2});
      await assert.rejects(running,/状态|取消/);assert.equal(f.search.snapshot().stage,'failed');
      assert.equal(f.calls.some(c=>c[0]==='turn'),false);
    });
    test(`deadline reached during ${phase} stops before any next operation`,async()=>{
      const f=fixture([{status:'not_found'}],{[phase]:async()=>{f.advance(120000);return {status:'found',subjectId:2};}});
      await assert.rejects(f.search.find(f.port),/超时/);
      assert.equal(f.search.snapshot().active,false);assert.equal(f.calls.some(c=>c[0]==='turn'),false);
    });
  }
  test('already stale state never calls a port operation',async()=>{
    const f=fixture();f.invalidate();await assert.rejects(f.search.find(f.port));assert.deepEqual(f.calls,[]);
  });
  test('a new turn is not started without a full two-second budget',async()=>{
    for(const elapsed of [118000,119999]){
      const f=fixture([],{inspect:async()=>{f.advance(elapsed);return {status:'not_found'};}});
      await assert.rejects(f.search.find(f.port),/超时|时间/);
      assert.equal(f.calls.some(c=>c[0]==='turn'),false);
    }
  });
  test('duplicate find rejects while the first search retains ownership',async()=>{
    const wait=deferred();const f=fixture([],{inspect:()=>wait.promise});
    const running=f.search.find(f.port);await Promise.resolve();
    await assert.rejects(f.search.find(f.port),/进行|搜索/);
    assert.equal(f.search.snapshot().active,true);wait.resolve({status:'found',subjectId:3});
    assert.equal(await running,3);
  });
  test('a progress-triggered cancellation does not dispatch the next port operation',async()=>{
    let search;const calls=[];
    search=new AutoSubjectSearch(()=>{if(search.snapshot().stage==='turning')search.cancel();},()=>0);
    await assert.rejects(search.find({isCurrent:()=>true,settle:async()=>{},inspect:async()=>({status:'not_found'}),turn:async()=>calls.push('turn')}),/取消/);
    assert.deepEqual(calls,[]);assert.equal(search.snapshot().stage,'cancelled');
  });
  test('snapshots are detached and a completed search can start a fresh budget',async()=>{
    const f=fixture([{status:'found',subjectId:1},{status:'found',subjectId:2}]);
    await f.search.find(f.port);const snapshot=f.search.snapshot();snapshot.active=true;snapshot.turns=80;
    f.advance(200000);assert.equal(await f.search.find(f.port),2);
    assert.equal(f.search.snapshot().turns,0);assert.deepEqual(f.calls.at(-1),['inspect',321000]);
  });
