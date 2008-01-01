# --
# Kernel/System/DB/oracle.pm - oracle database backend
# Copyright (C) 2001-2008 OTRS GmbH, http://otrs.org/
# --
# $Id: oracle.pm,v 1.27.2.2 2008-01-01 16:16:21 martin Exp $
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see http://www.gnu.org/licenses/gpl.txt.
# --

package Kernel::System::DB::oracle;

use strict;
use warnings;

use vars qw($VERSION);
$VERSION = '$Revision: 1.27.2.2 $';
$VERSION =~ s/^\$.*:\W(.*)\W.+?$/$1/;

sub new {
    my $Type = shift;
    my %Param = @_;

    # allocate new hash for object
    my $Self = {};
    bless ($Self, $Type);

    # check needed objects
    foreach (keys %Param) {
        $Self->{$_} = $Param{$_};
    }
    return $Self;
}

sub LoadPreferences {
    my $Self = shift;
    my %Param = @_;

    # db settings
    $Self->{'DB::Limit'} = 0;
    $Self->{'DB::DirectBlob'} = 0;
    $Self->{'DB::QuoteSingle'} = '\'';
    $Self->{'DB::QuoteBack'} = 0;
    $Self->{'DB::QuoteSemicolon'} = '';
    $Self->{'DB::Attribute'} = {
        LongTruncOk => 1,
        LongReadLen => 14*1024*1024,
    };
    # set current time stamp if different to "current_timestamp"
    $Self->{'DB::CurrentTimestamp'} = '';
    # set encoding of selected data to utf8
    $Self->{'DB::Encode'} = 0;

    # shell setting
    $Self->{'DB::Comment'} = '-- ';
    $Self->{'DB::ShellCommit'} = ';';
    $Self->{'DB::ShellConnect'} = 'SET DEFINE OFF';

    return 1;
}

sub Quote {
    my $Self = shift;
    my $Text = shift;
    if (defined(${$Text})) {
        if ($Self->{'DB::QuoteBack'}) {
            ${$Text} =~ s/\\/$Self->{'DB::QuoteBack'}\\/g;
        }
        if ($Self->{'DB::QuoteSingle'}) {
            ${$Text} =~ s/'/$Self->{'DB::QuoteSingle'}'/g;
        }
        if ($Self->{'DB::QuoteSemicolon'}) {
            ${$Text} =~ s/;/$Self->{'DB::QuoteSemicolon'};/g;
        }
    }
    return $Text;
}

sub DatabaseCreate {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    if (!$Param{Name}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need Name!");
        return;
    }
    # return SQL
    return ("CREATE DATABASE $Param{Name}");
}

sub DatabaseDrop {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    if (!$Param{Name}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need Name!");
        return;
    }
    # return SQL
    return ("DROP DATABASE $Param{Name}");
}

sub TableCreate {
    my $Self = shift;
    my @Param = @_;
    my $SQLStart = '';
    my $SQLEnd = '';
    my $SQL = '';
    my @Column = ();
    my $TableName = '';
    my $ForeignKey = ();
    my %Foreign = ();
    my $IndexCurrent = ();
    my %Index = ();
    my $UniqCurrent = ();
    my %Uniq = ();
    my $PrimaryKey = '';
    my @Return = ();
    my @Return2 = ();
    foreach my $Tag (@Param) {
        if ($Tag->{Tag} eq 'Table' && $Tag->{TagType} eq 'Start') {
            if ($Self->{ConfigObject}->Get('Database::ShellOutput')) {
                $SQLStart .= $Self->{'DB::Comment'}."----------------------------------------------------------\n";
                $SQLStart .= $Self->{'DB::Comment'}." create table $Tag->{Name}\n";
                $SQLStart .= $Self->{'DB::Comment'}."----------------------------------------------------------\n";
            }
        }
        if (($Tag->{Tag} eq 'Table' || $Tag->{Tag} eq 'TableCreate') && $Tag->{TagType} eq 'Start') {
            $SQLStart .= "CREATE TABLE $Tag->{Name} (\n";
            $TableName = $Tag->{Name};
        }
        if (($Tag->{Tag} eq 'Table' || $Tag->{Tag} eq 'TableCreate') && $Tag->{TagType} eq 'End') {
            $SQLEnd .= "\n)";
        }
        elsif ($Tag->{Tag} eq 'Column' && $Tag->{TagType} eq 'Start') {
            push (@Column, $Tag);
        }
        elsif ($Tag->{Tag} eq 'Index' && $Tag->{TagType} eq 'Start') {
            $IndexCurrent = $Tag->{Name};
        }
        elsif ($Tag->{Tag} eq 'IndexColumn' && $Tag->{TagType} eq 'Start') {
            push (@{$Index{$IndexCurrent}}, $Tag);
        }
        elsif ($Tag->{Tag} eq 'Unique' && $Tag->{TagType} eq 'Start') {
            $UniqCurrent = $Tag->{Name} || $TableName.'_U_'.int(rand(999));
        }
        elsif ($Tag->{Tag} eq 'UniqueColumn' && $Tag->{TagType} eq 'Start') {
            push (@{$Uniq{$UniqCurrent}}, $Tag);
        }
        elsif ($Tag->{Tag} eq 'ForeignKey' && $Tag->{TagType} eq 'Start') {
            $ForeignKey = $Tag->{ForeignTable};
        }
        elsif ($Tag->{Tag} eq 'Reference' && $Tag->{TagType} eq 'Start') {
            push (@{$Foreign{$ForeignKey}}, $Tag);
        }
    }
    foreach my $Tag (@Column) {
        # type translation
        $Tag = $Self->_TypeTranslation($Tag);
        if ($SQL) {
            $SQL .= ",\n";
        }
        # normal data type
        $SQL .= "    $Tag->{Name} $Tag->{Type}";
        if ($Tag->{Required} =~ /^true$/i) {
            $SQL .= " NOT NULL";
        }
        # add primary key
        my $Constraint = $TableName;
        if (length($Constraint) > 26) {
            $Constraint = substr($Constraint, 0, 24);
            $Constraint .= int(rand(99));
        }
        if ($Tag->{PrimaryKey} && $Tag->{PrimaryKey} =~ /true/i) {
            push (@Return2, "ALTER TABLE $TableName ADD CONSTRAINT $Constraint"."_PK PRIMARY KEY ($Tag->{Name})");
        }
        # auto increment
        if ($Tag->{AutoIncrement} && $Tag->{AutoIncrement} =~ /^true$/i) {
            my $Shell = '';
            if ($Self->{ConfigObject}->Get('Database::ShellOutput')) {
                $Shell = "/\n--";
            }
            push (@Return2, "DROP SEQUENCE $Constraint"."_seq");
            push (@Return2, "CREATE SEQUENCE $Constraint"."_seq");
            push (@Return2, "CREATE OR REPLACE TRIGGER $Constraint"."_s_t\n".
                "before insert on $TableName\n".
                "for each row\n".
                "begin\n".
                "    select $Constraint"."_seq.nextval\n".
                "    into :new.$Tag->{Name}\n".
                "    from dual;\nend;\n".
                "$Shell",
            );
        }
    }
    # add uniq
    my $UniqCunter = 0;
    foreach my $Name (keys %Uniq) {
        $UniqCunter++;
        if ($SQL) {
            $SQL .= ",\n";
        }
        $SQL .= "    CONSTRAINT $TableName"."_U_$UniqCunter UNIQUE (";
        my @Array = @{$Uniq{$Name}};
        foreach (0..$#Array) {
            if ($_ > 0) {
                $SQL .= ", ";
            }
            $SQL .= $Array[$_]->{Name};
        }
        $SQL .= ")";
    }
    push(@Return, $SQLStart.$SQL.$SQLEnd, @Return2);
    # add indexs
    foreach my $Name (keys %Index) {
        push (@Return, $Self->IndexCreate(
            TableName => $TableName,
            Name => $Name,
            Data => $Index{$Name},
        ));
    }
    # add uniq
#    foreach my $Name (keys %Uniq) {
#        push (@Return, $Self->UniqueCreate(
#            TableName => $TableName,
#            Name => $Name,
#            Data => $Uniq{$Name},
#        ));
#    }
    # add foreign keys
    foreach my $ForeignKey (keys %Foreign) {
        my @Array = @{$Foreign{$ForeignKey}};
        foreach (0..$#Array) {
            push (@{$Self->{Post}}, $Self->ForeignKeyCreate(
                LocalTableName => $TableName,
                Local => $Array[$_]->{Local},
                ForeignTableName => $ForeignKey,
                Foreign => $Array[$_]->{Foreign},
            ));
        }
    }
    return @Return;
}

sub TableDrop {
    my $Self = shift;
    my @Param = @_;
    my $SQL = '';
    foreach my $Tag (@Param) {
        if ($Tag->{Tag} eq 'Table' && $Tag->{TagType} eq 'Start') {
            if ($Self->{ConfigObject}->Get('Database::ShellOutput')) {
                $SQL .= $Self->{'DB::Comment'}."----------------------------------------------------------\n";
                $SQL .= $Self->{'DB::Comment'}." drop table $Tag->{Name}\n";
                $SQL .= $Self->{'DB::Comment'}."----------------------------------------------------------\n";
            }
        }
        $SQL .= "DROP TABLE $Tag->{Name} CASCADE CONSTRAINTS";
        return ($SQL);
    }
    return ();
}

sub TableAlter {
    my $Self = shift;
    my @Param = @_;
    my $SQLStart = '';
    my @SQL = ();
    my $Table = '';
    foreach my $Tag (@Param) {
        if ($Tag->{Tag} eq 'TableAlter' && $Tag->{TagType} eq 'Start') {
            if ($Self->{ConfigObject}->Get('Database::ShellOutput')) {
                $SQLStart .= $Self->{'DB::Comment'}."----------------------------------------------------------\n";
                $SQLStart .= $Self->{'DB::Comment'}." alter table $Tag->{Name}\n";
                $SQLStart .= $Self->{'DB::Comment'}."----------------------------------------------------------\n";
            }
            $SQLStart .= "ALTER TABLE $Tag->{Name}";
            $Table = $Tag->{Name};
        }
        elsif ($Tag->{Tag} eq 'ColumnAdd' && $Tag->{TagType} eq 'Start') {
            # Type translation
            $Tag = $Self->_TypeTranslation($Tag);
            # normal data type
            my $SQLEnd = $SQLStart." ADD $Tag->{Name} $Tag->{Type}";
            if (!$Tag->{Default} && $Tag->{Required} && $Tag->{Required} =~ /^true$/i) {
                $SQLEnd .= " NOT NULL";
            }
            # auto increment
            if ($Tag->{AutoIncrement} && $Tag->{AutoIncrement} =~ /^true$/i) {
                $SQLEnd .= " AUTO_INCREMENT";
            }
            # add primary key
            if ($Tag->{PrimaryKey} && $Tag->{PrimaryKey} =~ /true/i) {
                $SQLEnd .= " PRIMARY KEY($Tag->{Name})";
            }
            push (@SQL, $SQLEnd);
            # default values
            if ($Tag->{Default}) {
                if ($Tag->{Type} =~ /int/i) {
                    push (@SQL, "UPDATE $Table SET $Tag->{Name} = $Tag->{Default} WHERE $Tag->{Name} IS NULL");
                }
                else {
                    push (@SQL, "UPDATE $Table SET $Tag->{Name} = $Tag->{Default} WHERE '$Tag->{Name}' IS NULL");
                }
                if ($Tag->{Required} && $Tag->{Required} =~ /^true$/i) {
                    push (@SQL, "ALTER TABLE $Table MODIFY $Tag->{Name} $Tag->{Type} NOT NULL");
                }
            }
        }
        elsif ($Tag->{Tag} eq 'ColumnChange' && $Tag->{TagType} eq 'Start') {
            # Type translation
            $Tag = $Self->_TypeTranslation($Tag);
            # rename oldname to newname
            if ($Tag->{NameOld} ne $Tag->{NameNew}) {
                push (@SQL, $SQLStart." RENAME COLUMN $Tag->{NameOld} TO $Tag->{NameNew}");
            }
            # alter table name modify
            if (!$Tag->{Name} && $Tag->{NameNew}) {
                $Tag->{Name} = $Tag->{NameNew};
            }
            if (!$Tag->{Name} && $Tag->{NameOld}) {
                $Tag->{Name} = $Tag->{NameOld};
            }
            my $SQLEnd = $SQLStart." MODIFY $Tag->{Name} $Tag->{Type}";
            if ($Tag->{Required} && $Tag->{Required} =~ /^true$/i) {
                $SQLEnd .= " NOT NULL";
            }
            else {
                $SQLEnd .= " NULL";
            }
            # auto increment
            if ($Tag->{AutoIncrement} && $Tag->{AutoIncrement} =~ /^true$/i) {
                $SQLEnd .= " AUTO_INCREMENT";
            }
            # add primary key
            if ($Tag->{PrimaryKey} && $Tag->{PrimaryKey} =~ /true/i) {
                $SQLEnd .= " PRIMARY KEY($Tag->{Name})";
            }
            push (@SQL, $SQLEnd);
        }
        elsif ($Tag->{Tag} eq 'ColumnDrop' && $Tag->{TagType} eq 'Start') {
            my $SQLEnd = $SQLStart." DROP COLUMN $Tag->{Name}";
            push (@SQL, $SQLEnd);
        }
    }
    return @SQL;
}

sub IndexCreate {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(TableName Name Data)) {
        if (!$Param{$_}) {
            $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
            return;
        }
    }
    my $Index = $Param{Name};
    if (length($Index) > 30) {
        $Index = substr($Index, 0, 28);
        $Index .= int(rand(99));
    }
    my $SQL = "CREATE INDEX $Index ON $Param{TableName} (";
    my @Array = @{$Param{'Data'}};
    foreach (0..$#Array) {
        if ($_ > 0) {
            $SQL .= ", ";
        }
        $SQL .= $Array[$_]->{Name};
        if ($Array[$_]->{Size}) {
#           $SQL .= "($Array[$_]->{Size})";
        }
    }
    $SQL .= ")";
    # return SQL
    return ($SQL);

}

sub IndexDrop {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(TableName Name)) {
        if (!$Param{$_}) {
            $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
            return;
        }
    }
    my $SQL = "DROP INDEX $Param{Name}";
    return ($SQL);
}

sub ForeignKeyCreate {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(LocalTableName Local ForeignTableName Foreign)) {
        if (!$Param{$_}) {
            $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
            return;
        }
    }
    my $ForeignKey = "fk_$Param{LocalTableName}_$Param{Local}_$Param{Foreign}";
    if (length($ForeignKey) > 30) {
        $ForeignKey = substr($ForeignKey, 0, 28);
        $ForeignKey .= int(rand(99));
    }
    my $SQL = "ALTER TABLE $Param{LocalTableName} ADD CONSTRAINT $ForeignKey FOREIGN KEY (";
    $SQL .= "$Param{Local}) REFERENCES ";
    $SQL .= "$Param{ForeignTableName}($Param{Foreign})";
    # return SQL
    return ($SQL);
}

sub ForeignKeyDrop {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(TableName Name)) {
        if (!$Param{$_}) {
            $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
            return;
        }
    }
    my $SQL = "ALTER TABLE $Param{TableName} DISABLE CONSTRAINT $Param{Name}";
    return ($SQL);
}

sub UniqueCreate {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(TableName Name Data)) {
        if (!$Param{$_}) {
            $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
            return;
        }
    }
    my $SQL = "ALTER TABLE $Param{TableName} ADD CONSTRAINT $Param{Name} UNIQUE (";
    my @Array = @{$Param{'Data'}};
    foreach (0..$#Array) {
        if ($_ > 0) {
            $SQL .= ", ";
        }
        $SQL .= $Array[$_]->{Name};
    }
    $SQL .= ")";
    # return SQL
    return ($SQL);

}

sub UniqueDrop {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(TableName Name)) {
        if (!$Param{$_}) {
            $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
            return;
        }
    }
    my $SQL = "ALTER TABLE $Param{TableName} DROP CONSTRAINT $Param{Name}";
    return ($SQL);
}

sub Insert {
    my $Self = shift;
    my @Param = @_;
    my $SQL = '';
    my @Keys = ();
    my @Values = ();
    foreach my $Tag (@Param) {
        if ($Tag->{Tag} eq 'Insert' && $Tag->{TagType} eq 'Start') {
            if ($Self->{ConfigObject}->Get('Database::ShellOutput')) {
                $SQL .= $Self->{'DB::Comment'}."----------------------------------------------------------\n";
                $SQL .= $Self->{'DB::Comment'}." insert into table $Tag->{Table}\n";
                $SQL .= $Self->{'DB::Comment'}."----------------------------------------------------------\n";
            }
            $SQL .= "INSERT INTO $Tag->{Table} ";
        }
        if ($Tag->{Tag} eq 'Data' && $Tag->{TagType} eq 'Start') {
            $Tag->{Key} = ${$Self->Quote(\$Tag->{Key})};
            push (@Keys, $Tag->{Key});
            my $Value;
            if (defined($Tag->{Value})) {
                $Value = $Tag->{Value};
                $Self->{LogObject}->Log(
                    Priority => 'error',
                    Message => "The content for inserts is not longer appreciated attribut Value, use Content from now on! Reason: You can't use new lines in attributes.",
                );
            }
            elsif (defined($Tag->{Content})) {
                $Value = $Tag->{Content};
            }
            else {
                $Value = '';
            }
            if ($Tag->{Type} && $Tag->{Type} eq 'Quote') {
                $Value = "'".${$Self->Quote(\$Value)}."'";
            }
            else {
                $Value = ${$Self->Quote(\$Value)};
            }
            push (@Values, $Value);
        }
    }
    my $Key = '';
    foreach (@Keys) {
        if ($Key ne '') {
            $Key .= ", ";
        }
        $Key .= $_;
    }
    my $Value = '';
    foreach my $Tmp (@Values) {
        if ($Value ne '') {
            $Value .= ", ";
        }
        if ($Tmp eq 'current_timestamp') {
            if ($Self->{ConfigObject}->Get('Database::ShellOutput')) {
                $Value .= $Tmp;
            }
            else {
                my $Timestamp = $Self->{TimeObject}->CurrentTimestamp();
                $Value .= '\''.$Timestamp.'\'';
            }
        }
        else {
            if ($Self->{ConfigObject}->Get('Database::ShellOutput')) {
                $Tmp =~ s/\n/\r/g;
            }
            $Value .= $Tmp;
        }
    }
    $SQL .= "($Key)\n    VALUES\n    ($Value)";
    return ($SQL);
}

sub _TypeTranslation {
    my $Self = shift;
    my $Tag = shift;
    # Type translation
    if ($Tag->{Type} =~ /^DATE$/i) {
        $Tag->{Type} = 'DATE';
    }
    elsif ($Tag->{Type} =~ /^integer$/i) {
        $Tag->{Type} = 'NUMBER';
    }
    elsif ($Tag->{Type} =~ /^smallint$/i) {
        $Tag->{Type} = 'NUMBER (5, 0)';
    }
    elsif ($Tag->{Type} =~ /^bigint$/i) {
        $Tag->{Type} = 'NUMBER (20, 0)';
    }
    elsif ($Tag->{Type} =~ /^longblob$/i) {
        $Tag->{Type} = 'CLOB';
    }
    elsif ($Tag->{Type} =~ /^VARCHAR$/i) {
        $Tag->{Type} = "VARCHAR2 ($Tag->{Size})";
        if ($Tag->{Size}  > 4000) {
            $Tag->{Type} = "CLOB";
        }
    }
    elsif ($Tag->{Type} =~ /^DECIMAL$/i) {
        $Tag->{Type} = "DECIMAL ($Tag->{Size})";
    }
    return $Tag;
}

1;
