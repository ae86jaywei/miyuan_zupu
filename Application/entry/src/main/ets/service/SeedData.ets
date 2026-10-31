import { Person, createEmptyPerson } from '../model/Person';
import { Genealogy, createEmptyGenealogy } from '../model/Genealogy';

/**
 * 演示数据：李氏宗谱（虚构），用于首次启动展示五种谱式效果。
 */
export class SeedData {

  private static make(uid: string, gen: number, name: string, gender: string, genChar: string,
    lifeStatus: string, birth: string, death: string, birthPlace: string, fatherId: string,
    motherId: string, spouseId: string, rank: string, education: string, occupation: string,
    biography: string): Person {
    const p: Person = createEmptyPerson();
    p.uid = uid;
    p.generation = gen;
    p.name = name;
    p.gender = gender;
    p.generationChar = genChar;
    p.lifeStatus = lifeStatus;
    p.birthDate = birth;
    p.deathDate = death;
    p.birthPlace = birthPlace;
    p.fatherId = fatherId;
    p.motherId = motherId;
    p.spouseId = spouseId;
    p.rank = rank;
    p.education = education;
    p.occupation = occupation;
    p.biography = biography;
    p.residence = birthPlace;
    return p;
  }

  static people(): Person[] {
    const list: Person[] = [];
    // 一世 始祖
    const a1: Person = SeedData.make('F001', 1, '李德昌', '男', '德', '已故', '1820-03-12', '1890-11-02',
      '广东-梅州-兴宁-罗岗镇-霞岚村', '', '', 'M001', '长子', '私塾', '耕读传家',
      '李德昌，字厚斋，清道光年间自嘉应州迁居兴宁罗岗，垦荒置田，立字派“德泽承先志，光宗耀后贤”，为罗岗李氏开基始祖。');
    const m1: Person = SeedData.make('M001', 1, '林氏', '女', '德', '已故', '1823-08-20', '1888-05-16',
      '广东-梅州-兴宁-罗岗镇', '', '', 'F001', '', '', '持家有道',
      '林氏，温恭勤俭，助夫立业，乡里称贤。');
    // 二世
    const a2: Person = SeedData.make('F002', 2, '李泽清', '男', '泽', '已故', '1846-02-08', '1912-04-19',
      '广东-梅州-兴宁-罗岗镇-霞岚村', 'F001', 'M001', 'M002', '长子', '秀才', '乡塾先生',
      '泽清公，光绪年间秀才，设馆授徒三十余年，弟子遍及兴宁，主修首次族谱。');
    const a2b: Person = SeedData.make('F003', 2, '李泽明', '男', '泽', '已故', '1849-09-01', '1905-07-22',
      '广东-梅州-兴宁-罗岗镇-霞岚村', 'F001', 'M001', 'M003', '次子', '', '农商并营',
      '泽明公，贸易于潮汕之间，携族资建宗祠“陇西堂”。');
    const a2c: Person = SeedData.make('M004', 2, '李泽莲', '女', '泽', '已故', '1855-01-15', '',
      '广东-梅州-兴宁-罗岗镇-霞岚村', 'F001', 'M001', '', '长女', '', '',
      '泽莲，适同邑陈氏，贤淑有母风。');
    // 三世
    const a3: Person = SeedData.make('F004', 3, '李承业', '男', '承', '已故', '1872-06-30', '1941-01-11',
      '广东-梅州-兴宁-罗岗镇-霞岚村', 'F002', 'M002', '', '长子', '国学生', '县衙书吏',
      '承业公，号敬亭，精于账法，曾主修水利，泽被乡里。');
    const a3b: Person = SeedData.make('F005', 3, '李承志', '男', '承', '已故', '1876-10-12', '1936-03-04',
      '广东-梅州-兴宁-罗岗镇-霞岚村', 'F002', 'M002', '', '次子', '', '商号掌柜',
      '承志公，经营米行，乐善好施，荒年施粥三月。');
    const a3c: Person = SeedData.make('F006', 3, '李承恩', '男', '承', '已故', '1882-05-21', '1958-12-09',
      '广东-梅州-兴宁-罗岗镇-霞岚村', 'F003', 'M003', '', '长子', '师范', '小学校长',
      '承恩公，创办霞岚小学，开乡里新学之风。');
    // 四世
    const a4: Person = SeedData.make('F007', 4, '李先觉', '男', '先', '已故', '1901-04-03', '1978-08-17',
      '广东-梅州-兴宁-罗岗镇', 'F004', '', '', '长子', '', '县中学教员',
      '先觉公，避难南洋数年，归乡后执教终身。');
    const a4b: Person = SeedData.make('F008', 4, '李先民', '男', '先', '已故', '1908-11-26', '1993-02-15',
      '广东-梅州-兴宁-罗岗镇', 'F005', '', '', '长子', '', '农民',
      '先民公，耕读传家，重修族谱手抄本两卷。');
    const a4c: Person = SeedData.make('M008', 4, '李先慧', '女', '先', '已故', '1912-07-07', '2001-06-30',
      '广东-梅州-兴宁-罗岗镇', 'F005', '', '', '长女', '师范', '教师',
      '先慧，执教三十八年，桃李满门。');
    // 五世
    const a5: Person = SeedData.make('F009', 5, '李志远', '男', '志', '在世', '1940-09-18', '',
      '广东-梅州-兴宁-罗岗镇', 'F007', '', '', '长子', '大专-华南师范学院', '中学校长',
      '志远，退休后致力于整理祖谱文献，主持第五次修谱。');
    const a5b: Person = SeedData.make('F010', 5, '李志诚', '男', '志', '在世', '1948-02-02', '',
      '广东-梅州-兴宁-罗岗镇', 'F008', '', '', '长子', '高中', '建筑工程师',
      '志诚，参与家乡道路桥梁建设，捐资修缮宗祠。');
    const a5c: Person = SeedData.make('M010', 5, '李志兰', '女', '志', '在世', '1952-12-11', '',
      '广东-梅州-兴宁-罗岗镇', 'F008', '', '', '次女', '中专', '护士',
      '志兰，从事儿科护理三十余年。');
    // 六世
    const a6: Person = SeedData.make('F011', 6, '李光宇', '男', '光', '在世', '1976-03-05', '',
      '广东-广州-天河区', 'F009', '', '', '长子', '硕士-华南理工大学', '高级工程师',
      '光宇，从事通信技术研发，现居广州，负责本次族谱数字化。');
    const a6b: Person = SeedData.make('F012', 6, '李光耀', '男', '光', '在世', '1980-05-20', '',
      '广东-梅州-兴宁', 'F010', '', '', '长子', '本科-中山大学', '会计师',
      '光耀，任职于会计师事务所，热衷家族公益。');
    const a6c: Person = SeedData.make('M012', 6, '李光月', '女', '光', '在世', '1985-08-08', '',
      '广东-深圳-南山区', 'F010', '', '', '长女', '本科-暨南大学', '设计师',
      '光月，平面设计师，为宗谱设计封面。');
    // 七世
    const a7: Person = SeedData.make('F013', 7, '李宗琪', '男', '宗', '在世', '2008-06-16', '',
      '广东-广州-天河区', 'F011', '', '', '长子', '在读高中', '学生',
      '宗琪，品学兼优，好书法。');
    const a7b: Person = SeedData.make('M014', 7, '李宗琳', '女', '宗', '在世', '2013-10-01', '',
      '广东-梅州-兴宁', 'F012', '', '', '长女', '在读小学', '学生',
      '宗琳，活泼好学。');

    list.push(a1, m1, a2, a2b, a2c, a3, a3b, a3c, a4, a4b, a4c, a5, a5b, a5c, a6, a6b, a6c, a7, a7b);
    return list;
  }

  static defaultBook(): Genealogy {
    const b: Genealogy = createEmptyGenealogy();
    b.title = '李氏宗谱';
    b.surname = '李';
    b.hallName = '陇西堂';
    b.junwang = '陇西郡';
    b.ancestorName = '李德昌';
    b.generationPoem = '德泽承先志，光宗耀后贤';
    b.preface = '木有本，水有源。吾族自德昌公迁居罗岗，迄今七世，瓜瓞绵延，子孙繁盛。' +
      '今以数字之器，录族人之名讳、生卒、行实，使后世子孙知所从来，念祖德而绍家风。';
    b.familyRules = '一、孝悌为先，敬事父母；\n二、耕读传家，务本崇文；\n三、敦亲睦族，患难相恤；\n' +
      '四、勤俭持家，戒奢戒惰；\n五、守法奉公，正直为人；\n六、修身齐家，光大门楣。';
    b.editingNotes = '本谱依《关键信息字段_20261023》规范录入：世代、唯—ID、谱名、曾用名、性别、辈分字派、' +
      '在世状态、生卒日期（公历/农历双标）、出生地、现居地、父母ID、排行、过继、学历、职业、生平、墓葬GPS、' +
      '联系方式与图像资料。';
    return b;
  }
}
