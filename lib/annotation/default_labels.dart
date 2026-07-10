import 'models.dart';

const defaultLabelNames = <String>[
  'Walnut Donut',
  'Croffle',
  'Waffle',
  'Scon',
  'Half-moon Croissant',
  'Croissant',
  'Flower Bread',
  'Almond Scon',
  'Dinner Roll',
  'Sugar Donut',
  'Bagel',
  'Egg Tart',
  'Muffin',
  'Burger',
  'Sandwich',
  'Grain  Campagne',
  'Almond Campagne',
  'Mini Bread',
  'Pastry Bread',
  'Plain Bread',
];

const defaultLabelColors = <int>[
  0xff7c3aed,
  0xff2563eb,
  0xff16a34a,
  0xffea580c,
  0xffdb2777,
  0xff0891b2,
];

const defaultLabelShortcuts = <String>[
  '1',
  '2',
  '3',
  '4',
  '5',
  '6',
  '7',
  '8',
  '9',
  '0',
  'q',
  'w',
  'e',
  'r',
  't',
  'y',
  'u',
  'i',
  'o',
  'p',
];

List<LabelClass> createDefaultLabels() {
  return [
    for (var index = 0; index < defaultLabelNames.length; index++)
      LabelClass(
        id: index + 1,
        name: defaultLabelNames[index],
        color: defaultLabelColors[index % defaultLabelColors.length],
        shortcut: index < defaultLabelShortcuts.length
            ? defaultLabelShortcuts[index]
            : null,
      ),
  ];
}
