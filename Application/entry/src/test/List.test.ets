import peopleStoreTest from './PeopleStore.test';
import spouseRelationsTest from './SpouseRelations.test';
import queryAndSearchTest from './QueryAndSearch.test';

export default function testsuite() {
  peopleStoreTest();
  spouseRelationsTest();
  queryAndSearchTest();
}
