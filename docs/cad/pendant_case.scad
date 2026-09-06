// OpenPendant clamshell — PETG, 0.2 mm layers, 3 walls.
// USB-C window on the bottom seam. No SD slot: open the lid to reach the card.
// Units: millimetres.

inner_w = 23;
inner_h = 48;
inner_d_back = 8.0;
inner_d_front = 7.0;
wall = 1.6;
usb_w = 12.0;
usb_h = 5.4;
mic_y = 17;
mic_r = 1.5;
led_y = 7;
led_r = 1.2;
btn_y = 44.5;
btn_r = 3.3;
bail_h = 8;
bail_t = 3;
$fn = 32;

outer_w = inner_w + 2 * wall;
outer_h = inner_h + 2 * wall;

module usb_cut(z, h) {
  translate([-usb_w / 2, -1, z]) cube([usb_w, wall + 2, h]);
}

module back() {
  difference() {
    union() {
      difference() {
        cube([outer_w, outer_h, inner_d_back + wall], center = false);
        translate([wall, wall, wall])
          cube([inner_w, inner_h, inner_d_back + 1]);
      }
      // cord bail
      translate([outer_w / 2 - 8, outer_h, 0]) cube([3, bail_h, bail_t]);
      translate([outer_w / 2 + 5, outer_h, 0]) cube([3, bail_h, bail_t]);
      translate([outer_w / 2 - 8, outer_h + bail_h - bail_t, 0])
        cube([16, bail_t, bail_t]);
    }
    usb_cut(inner_d_back + wall - usb_h, usb_h + 1);
    // fingernail grooves
    translate([-0.1, outer_h / 2 - 7, inner_d_back + wall - 3.4])
      cube([1.3, 14, 3.6]);
    translate([outer_w - 1.2, outer_h / 2 - 7, inner_d_back + wall - 3.4])
      cube([1.3, 14, 3.6]);
  }
}

module front() {
  difference() {
    cube([outer_w, outer_h, inner_d_front + wall], center = false);
    translate([wall, wall, -1]) cube([inner_w, inner_h, inner_d_front + 1]);
    usb_cut(-1, usb_h + 1);
    translate([outer_w / 2, wall + mic_y, inner_d_front])
      cylinder(h = wall + 2, r = mic_r);
    translate([outer_w / 2, wall + led_y, inner_d_front])
      cylinder(h = wall + 2, r = led_r);
    translate([outer_w / 2 + 1.27, wall + btn_y, inner_d_front])
      cylinder(h = wall + 2, r = btn_r);
  }
}

// Preview both; export each module separately for print.
translate([-outer_w - 4, 0, 0]) back();
front();
