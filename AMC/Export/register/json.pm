#
# Copyright (C) 2012,2014 Alexis Bienvenue <paamc@passoire.fr>
#
# This file is part of Auto-Multiple-Choice
#
# Auto-Multiple-Choice is free software: you can redistribute it
# and/or modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation, either version 2 of
# the License, or (at your option) any later version.
#
# Auto-Multiple-Choice is distributed in the hope that it will be
# useful, but WITHOUT ANY WARRANTY; without even the implied warranty
# of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Auto-Multiple-Choice.  If not, see
# <http://www.gnu.org/licenses/>.

package AMC::Export::register::json;

use AMC::Export::register;
use AMC::Basic;
use AMC::Gui::Prefs;

@ISA=("AMC::Export::register");

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new();
    bless ($self, $class);
    return $self;
}

sub name {
  return('json');
}

sub extension {
  return('.json');
}

sub options_from_config {
  my ($self,$config)=@_;
  my $enc=$config->get("encodage_json")
    || $config->get("defaut_encodage_json")
    || "UTF-8";
  return(encodage=>$enc,
	 columns=>$config->get('export_json_columns'),
	 decimal=>$config->get('delimiteur_decimal'),
	 ticked=>$config->get('export_json_ticked'),
	);
}

sub options_default {
  return(
	 export_csv_ticked=>'',
	 export_csv_columns=>'student.copy,student.key,student.name',
	);
}
sub needs_module {
  return('JSON');
}
sub build_config_gui {
  my ($self,$w,$prefs)=@_;
  my $t=Gtk3::Grid->new();
  my $widget;
  my $y=0;
  my $renderer;

  $t->attach(Gtk3::Label->new(__"Separator"),
	     0,$y,1,1);

  $t->attach(Gtk3::Label->new(__"Ticked boxes"),
             0,$y,1,1);
  $widget=Gtk3::ComboBox->new();
  $renderer = Gtk3::CellRendererText->new();
  $widget->pack_start($renderer, TRUE);
  $widget->add_attribute($renderer,'text',COMBO_TEXT);
  $prefs->store_register('export_json_ticked'=>cb_model(""=>__"No",
						       "01"=>(__"Yes:")." 0;0;1;0",
						       "AB"=>(__"Yes:")." AB",
						      ));
  $w->{'export_c_export_json_ticked'}=$widget;
  $t->attach($widget,1,$y,1,1);
  $y++;

  $widget=Gtk3::Button->new_with_label(__"Choose columns");
  $widget->signal_connect(clicked => \&main::choose_columns_current);
  $t->attach($widget,0,$y,2,1);
  $y++;

  $t->show_all;
  return($t);
}

sub weight {
  return(.9);
}

1;
