import 'package:drift/drift.dart';

// 로컬 DB 스키마 초안. 테이블 정의만 있으며 AppDatabase 연결/DAO/마이그레이션은 아직 없다.
// 이미지 파일 자체는 여기 저장하지 않고, path_provider 앱 문서 디렉터리에 저장된
// 실제 파일의 경로 문자열만 저장한다.

class Clothes extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get imagePath => text()();
  TextColumn get category => text()();
  TextColumn get color => text()();
  TextColumn get season => text()();
  TextColumn get brand => text().nullable()();
  TextColumn get memo => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class Outfits extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get memo => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class OutfitItems extends Table {
  IntColumn get outfitId => integer().references(Outfits, #id)();
  IntColumn get clothesId => integer().references(Clothes, #id)();

  @override
  Set<Column> get primaryKey => {outfitId, clothesId};
}

class FittingHistory extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get sourceImagePath => text()();
  TextColumn get resultImagePath => text()();
  IntColumn get clothesId => integer().nullable().references(Clothes, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  TextColumn get provider => text()();
}
