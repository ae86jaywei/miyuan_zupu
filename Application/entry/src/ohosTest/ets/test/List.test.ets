import personRepositoryTest from './PersonRepository.test';
import bookManagerTest from './BookManager.test';
import importManagerTest from './ImportManager.test';

export default function testsuite() {
  personRepositoryTest();
  bookManagerTest();
  importManagerTest();
}
