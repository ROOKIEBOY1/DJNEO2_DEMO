import localUnitTest from './LocalUnit.test';
import protocolTest from './Protocol.test';

export default function testsuite() {
  localUnitTest();
  protocolTest();
}
