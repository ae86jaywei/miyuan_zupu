import personRepositoryTest from './PersonRepository.test';
import bookManagerTest from './BookManager.test';
import importManagerTest from './ImportManager.test';
import branchManagerTest from './BranchManager.test';
import restoreManagerTest from './RestoreManager.test';
import cloudReplayTest from './CloudReplay.test';
import cloudCollaborationTest from './CloudCollaboration.test';

export default function testsuite() {
  personRepositoryTest();
  bookManagerTest();
  importManagerTest();
  branchManagerTest();
  restoreManagerTest();
  cloudReplayTest();
  cloudCollaborationTest();
}
