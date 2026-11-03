import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/services/kerrigan_name/kerrigan_names_registrar.dart';

void main() {
  test("orders, as the registrar names them", () {
    String spelled(KerriganNamesSort s, {required bool my}) =>
        "${s.key(my: my)} ${s.order}";
    expect(
      [for (final s in KerriganNamesSort.values) spelled(s, my: true)],
      [
        "name asc",
        "name desc",
        "price asc",
        "price desc",
        "updated desc",
        "updated asc",
      ],
    );
    expect(
      [for (final s in KerriganNamesSort.values) spelled(s, my: false)],
      [
        "name asc",
        "name desc",
        "price asc",
        "price desc",
        "listed desc",
        "listed asc",
      ],
    );
  });

  test("statuses, as the registrar names them", () {
    expect(
      [for (final s in KerriganNamesStatusFilter.values) s.key],
      ["all", "listed", "not_listed"],
    );
    expect(kKerriganNamesNoFilter, (
      status: KerriganNamesStatusFilter.all,
      zone: null,
      sort: KerriganNamesSort.nameAsc,
    ));
  });
}
