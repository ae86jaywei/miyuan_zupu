import peopleStoreTest from './PeopleStore.test';
import spouseRelationsTest from './SpouseRelations.test';
import queryAndSearchTest from './QueryAndSearch.test';
import personEditorTest from './PersonEditor.test';
import personIndexTest from './PersonIndex.test';

export default function testsuite() {
  peopleStoreTest();
  spouseRelationsTest();
  queryAndSearchTest();
  personEditorTest();
  personIndexTest();
}
