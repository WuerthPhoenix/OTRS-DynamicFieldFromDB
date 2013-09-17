# --
# Kernel/System/DynamicField/Backend/Dropdown.pm - Delegate for DynamicField Dropdown backend
# Copyright (C) 2001-2012 OTRS AG, http://otrs.org/
# --
# $Id: Dropdown.pm,v 1.63 2012/04/02 11:46:35 mg Exp $
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::System::DynamicField::Backend::DropdownFromDB;

use strict;
use warnings;
use DBI;

use Kernel::System::VariableCheck qw(:all);
use Kernel::System::DynamicFieldValue;
use Kernel::System::DynamicField::Backend::BackendCommon;
use Kernel::System::Cache;
use Kernel::System::Ticket;
#use Kernel::System::CacheInternal;

use vars qw($VERSION);
$VERSION = qw($Revision: 1.63 $) [1];

=head1 NAME

Kernel::System::DynamicField::Backend::Dropdown

=head1 SYNOPSIS

DynamicFields Dropdown backend delegate

=head1 PUBLIC INTERFACE

This module implements the public interface of L<Kernel::System::DynamicField::Backend>.
Please look there for a detailed reference of the functions.

=over 4

=item new()

usually, you want to create an instance of this
by using Kernel::System::DynamicField::Backend->new();

=cut

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    # get needed objects
    for my $Needed (qw(ConfigObject EncodeObject LogObject MainObject DBObject)) {
        die "Got no $Needed!" if !$Param{$Needed};

        $Self->{$Needed} = $Param{$Needed};
    }

    # create additional objects
    $Self->{DynamicFieldValueObject} = Kernel::System::DynamicFieldValue->new( %{$Self} );
    $Self->{BackendCommonObject}
        = Kernel::System::DynamicField::Backend::BackendCommon->new( %{$Self} );

    $Self->{CacheObject} = Kernel::System::Cache->new(%Param);

    return $Self;
}

sub ValueGet {
    my ( $Self, %Param ) = @_;

    my $DFValue = $Self->{DynamicFieldValueObject}->ValueGet(
        FieldID  => $Param{DynamicFieldConfig}->{ID},
        ObjectID => $Param{ObjectID},
    );

    return if !$DFValue;
    return if !IsArrayRefWithData($DFValue);
    return if !IsHashRefWithData( $DFValue->[0] );

    return $DFValue->[0]->{ValueText};
}

sub ValueSet {
    my ( $Self, %Param ) = @_;

#    # check for valid possible values list
#    if ( !$Param{DynamicFieldConfig}->{Config}->{PossibleValues} ) {
#        $Self->{LogObject}->Log(
#            Priority => 'error',
#            Message  => "Need PossibleValues in DynamicFieldConfig!",
#        );
#        return;
#    }

    my $Success = $Self->{DynamicFieldValueObject}->ValueSet(
        FieldID  => $Param{DynamicFieldConfig}->{ID},
        ObjectID => $Param{ObjectID},
        Value    => [
            {
                ValueText => $Param{Value},
            },
        ],
        UserID => $Param{UserID},
    );

    return $Success;
}

sub ValueDelete {
    my ( $Self, %Param ) = @_;

    my $Success = $Self->{DynamicFieldValueObject}->ValueDelete(
        FieldID  => $Param{DynamicFieldConfig}->{ID},
        ObjectID => $Param{ObjectID},
        UserID   => $Param{UserID},
    );

    return $Success;
}

sub AllValuesDelete {
    my ( $Self, %Param ) = @_;

    my $Success = $Self->{DynamicFieldValueObject}->AllValuesDelete(
        FieldID => $Param{DynamicFieldConfig}->{ID},
        UserID  => $Param{UserID},
    );

    return $Success;
}

sub ValueValidate {
    my ( $Self, %Param ) = @_;

    my $Success = $Self->{DynamicFieldValueObject}->ValueValidate(
        Value => {
            ValueText => $Param{Value},
        },
        UserID => $Param{UserID}
    );

    return $Success;
}

sub SearchSQLGet {
    my ( $Self, %Param ) = @_;

    my %Operators = (
        Equals            => '=',
        GreaterThan       => '>',
        GreaterThanEquals => '>=',
        SmallerThan       => '<',
        SmallerThanEquals => '<=',
    );

    if ( $Operators{ $Param{Operator} } ) {
        my $SQL = " $Param{TableAlias}.value_text $Operators{$Param{Operator}} '";
        $SQL .= $Self->{DBObject}->Quote( $Param{SearchTerm} ) . "' ";
        return $SQL;
    }

    if ( $Param{Operator} eq 'Like' ) {

        my $SQL = $Self->{DBObject}->QueryCondition(
            Key   => "$Param{TableAlias}.value_text",
            Value => $Param{SearchTerm},
        );

        return $SQL;
    }

    $Self->{'LogObject'}->Log(
        'Priority' => 'error',
        'Message'  => "Unsupported Operator $Param{Operator}",
    );

    return;
}

sub SearchSQLOrderFieldGet {
    my ( $Self, %Param ) = @_;

    return "$Param{TableAlias}.value_text";
}

sub EditFieldRender {
    my ( $Self, %Param ) = @_;

    # take config from field config
    my $FieldConfig = $Param{DynamicFieldConfig}->{Config};
    my $FieldName   = 'DynamicField_' . $Param{DynamicFieldConfig}->{Name};
    my $FieldLabel  = $Param{DynamicFieldConfig}->{Label};

    my $Value = '';

    # set the field value or default
    if ( $Param{UseDefaultValue} ) {
        $Value = ( defined $FieldConfig->{DefaultValue} ? $FieldConfig->{DefaultValue} : '' );
    }
    $Value = $Param{Value} if defined $Param{Value};

    # extract the dynamic field value form the web request
    my $FieldValue = $Self->EditFieldValueGet(
        %Param,
    );

    # set values from ParamObject if present
    if ( defined $FieldValue ) {
        $Value = $FieldValue;
    }
    # check and set class if necessary
    my $FieldClass = 'DynamicFieldText';
    if ( defined $Param{Class} && $Param{Class} ne '' ) {
        $FieldClass .= ' ' . $Param{Class};
    }
    $FieldClass .= ' FromDB';

    # set field as mandatory
    $FieldClass .= ' Validate_Required' if $Param{Mandatory};

    # set error css class
    $FieldClass .= ' ServerError' if $Param{ServerError};

    # set PossibleValues
    my $SelectionData = $FieldConfig->{PossibleValues};

    ### FOTH preload data at creation
    $SelectionData = $Self->AJAXPossibleValuesGet(%Param, ForceQuery => 1);
    ### END FOTH

    # use PossibleValuesFilter if defined
    $SelectionData = $Param{PossibleValuesFilter}
        if defined $Param{PossibleValuesFilter};

    # set PossibleNone attribute
    my $FieldPossibleNone;
    if ( defined $Param{OverridePossibleNone} ) {
        $FieldPossibleNone = $Param{OverridePossibleNone};
    }
    else {
        $FieldPossibleNone = $FieldConfig->{PossibleNone} || 0;
    }

    my $HTMLString = $Param{LayoutObject}->BuildSelection(
        Data => $SelectionData || {},
        Name => $FieldName,
        SelectedID   => $Value,
        Translation  => $FieldConfig->{TranslatableValues} || 0,
        PossibleNone => 0, # we do not need to set possibleNone value because we do it already in the AJAXPossibibleValuesGet
        Class        => $FieldClass,
        HTMLQuote    => 1,
    );
    
    if ($FieldConfig->{DisplayErrors}) {
    	my $DivID = $FieldName . 'Warning';
    	
    	# for client side validation
        $HTMLString .= <<"EOF";
    <div style="color:red">\$Text{"[Debug mode]"}</div>
EOF
    }    

    if ( $Param{Mandatory} ) {
        my $DivID = $FieldName . 'Error';

        # for client side validation
        $HTMLString .= <<"EOF";

    <div id="$DivID" class="TooltipErrorMessage">
        <p>
            \$Text{"This field is required."}
        </p>
    </div>
EOF
    }

    if ( $Param{ServerError} ) {

        my $ErrorMessage = $Param{ErrorMessage} || 'This field is required.';
        my $DivID = $FieldName . 'ServerError';

        # for server side validation
        $HTMLString .= <<"EOF";
    <div id="$DivID" class="TooltipErrorMessage">
        <p>
            \$Text{"$ErrorMessage"}
        </p>
    </div>
EOF
    }

    if ( $Param{AJAXUpdate} or 1 ) {

        my $FieldSelector = '#' . $FieldName;

        my $FieldsToUpdate = '';
        if ( IsArrayRefWithData( $Param{UpdatableFields} ) ) {
            my $FirstItem = 1;
            FIELD:
            for my $Field ( @{ $Param{UpdatableFields} } ) {
                next FIELD if $Field eq $FieldName;
                if ($FirstItem) {
                    $FirstItem = 0;
                }
                else {
                    $FieldsToUpdate .= ', ';
                }
                $FieldsToUpdate .= "'" . $Field . "'";
            }
        }

        #add js to call FormUpdate()
        $HTMLString .= <<"EOF";
<!--dtl:js_on_document_complete-->
<script type="text/javascript">//<![CDATA[
    \$('$FieldSelector').bind('change', function (Event) {
        Core.AJAX.FormUpdate(\$(this).parents('form'), 'AJAXUpdate', '$FieldName', [ $FieldsToUpdate ]);
    });
//]]></script>
<!--dtl:js_on_document_complete-->
EOF
    }


    if ( $Param{SubmitOnChange} ) {

        my $FieldSelector = '#' . $FieldName;

        #add js to disable validation and do submit()
        $HTMLString .= <<"EOF";
<!--dtl:js_on_document_complete-->
<script type="text/javascript">//<![CDATA[
    \$('$FieldSelector').bind('change', function (Event) {
        // make sure the ticket is not yet created on queue change
        \$('input#Expand').val(1);
        Core.Form.Validate.DisableValidation(\$(this).closest('form'));
        \$(this).closest('form').submit();
    });
//]]></script>
<!--dtl:js_on_document_complete-->
EOF
    }

#	/DynamicFieldConfig
#	$Param{DynamicFieldConfig}->{Config}->{PossibleValues} = $Self->AJAXPossibleValuesGet(%Param);

    # call EditLabelRender on the common backend
    my $LabelString = $Self->{BackendCommonObject}->EditLabelRender(
        DynamicFieldConfig => $Param{DynamicFieldConfig},
        Mandatory          => $Param{Mandatory} || '0',
        FieldName          => $FieldName,
    );

    my $Data = {
        Field => $HTMLString,
        Label => $LabelString,
    };


    return $Data;
}

sub EditFieldValueGet {
    my ( $Self, %Param ) = @_;

    my $FieldName = 'DynamicField_' . $Param{DynamicFieldConfig}->{Name};

    my $Value;

    # check if there is a Template and retreive the dinalic field value from there
    if ( IsHashRefWithData( $Param{Template} ) ) {
        $Value = $Param{Template}->{$FieldName};
    }

    # otherwise get dynamic field value form param
    else {
        $Value = $Param{ParamObject}->GetParam( Param => $FieldName );
    }

    if ( defined $Param{ReturnTemplateStructure} && $Param{ReturnTemplateStructure} eq 1 ) {
        return {
            $FieldName => $Value,
        };
    }

    # for this field the normal return an the ReturnValueStructure are the same
    return $Value;
}

sub EditFieldValueValidate {
    my ( $Self, %Param ) = @_;

    # get the field value from the http request
    my $Value = $Self->EditFieldValueGet(
        DynamicFieldConfig => $Param{DynamicFieldConfig},
        ParamObject        => $Param{ParamObject},

        # not necessary for this backend but place it for consistency reasons
        ReturnValueStructure => 1,
    );

    my $ServerError;
    my $ErrorMessage;

    # perform necessary validations
    if ( $Param{Mandatory} && !$Value ) {
        return {
            ServerError => 1,
        };
    }
#    else {
#
#        # get possible values list
#        my $PossibleValues = $Param{DynamicFieldConfig}->{Config}->{PossibleValues};
#
#        # overwrite possible values if PossibleValuesFilter
#        if ( defined $Param{PossibleValuesFilter} ) {
#            $PossibleValues = $Param{PossibleValuesFilter}
#        }
#
#        # validate if value is in possible values list (but let pass empty values)
#        if ( $Value && !$PossibleValues->{$Value} ) {
#            $ServerError  = 1;
#            $ErrorMessage = 'The field content is invalid';
#        }
#    }

    # Validate anything (for now)
    my $Result = {
        ServerError  => $ServerError,
        ErrorMessage => $ErrorMessage,
    };

    return $Result;
}

sub DisplayValueRender {
    my ( $Self, %Param ) = @_;

    if ( !defined $Param{HTMLOutput} ) {
        $Param{HTMLOutput} = 1;
    }

    # get raw Value strings from field value
    my $Value = defined $Param{Value} ? $Param{Value} : '';
    my $Key = $Value;


    # get value from stored value in the DB if option is set
    if ($Param{DynamicFieldConfig}->{Config}->{StoreValue} eq "1") {
        $Value =~ s/^([^|]+)\|\|(.+)$/$2/;
    }
    else {
        my %PossibleValues;
    #	Type => 'Hash',
    #	Key => $Param{DynamicFieldConfig}->{Config}->{Name},
    #    );
    
    #    if ( !defined %PossibleValues ) {
        my @row;
        my $dbh;
        my $sth;

        if ( !$Param{DynamicFieldConfig}->{Config}->{DBIstring} ) {
            $Self->{DBObject}->Prepare(
                SQL => $Param{DynamicFieldConfig}->{Config}->{VisualQuery},
        		Bind => $Key,
            );

            #fetch first row
            @row = $Self->{DBObject}->FetchrowArray();

        } else {
            $dbh = DBI->connect($Param{DynamicFieldConfig}->{Config}->{DBIstring}, $Param{DynamicFieldConfig}->{Config}->{DBIuser}, $Param{DynamicFieldConfig}->{Config}->{DBIpass},
                              { PrintError => 0, AutoCommit => 0, HandleError => \&PossibleValuesError }) or return $Self->PossibleValuesError("could not connect to DB: $DBI::errstr");
        
            $dbh->{'mysql_enable_utf8'} = 1;
    
            $sth = $dbh->prepare($Param{DynamicFieldConfig}->{Config}->{VisualQuery});
            $sth->execute( $Key );
    
            # fetch first row
            @row = $sth->fetchrow_array;        
        }
    
    	my $line = '';
    	for my $col (@row) {
    	    $line .= $col.$Param{DynamicFieldConfig}->{Config}->{Separator};
    	}
    	$line = substr($line, 0, -1 * length($Param{DynamicFieldConfig}->{Config}->{Separator}));
    
        if ( $Param{DynamicFieldConfig}->{Config}->{DBIstring} ) {
            $dbh->disconnect;
        }

        $Value = $line;
    
        #$Value = $line; WP - DENI 20130825 

        # get real value
        if ( $PossibleValues{$Value} ) {
                
            # get readeable value
            $Value = $PossibleValues{$Value};
        }
    }
   
    # check is needed to translate values
    if ( $Param{DynamicFieldConfig}->{Config}->{TranslatableValues} ) {

        # translate value
        $Value = $Param{LayoutObject}->{LanguageObject}->Get($Value);
    }

    # set title as value after update and before limit
    my $Title = $Value;

    # HTMLOuput transformations
    if ( $Param{HTMLOutput} ) {
        $Value = $Param{LayoutObject}->Ascii2Html(
            Text => $Value,
            Max => $Param{ValueMaxChars} || '',
        );

        $Title = $Param{LayoutObject}->Ascii2Html(
            Text => $Title,
            Max => $Param{TitleMaxChars} || '',
        );
    }
    else {
        if ( $Param{ValueMaxChars} && length($Value) > $Param{ValueMaxChars} ) {
            $Value = substr( $Value, 0, $Param{ValueMaxChars} ) . '...';
        }
        if ( $Param{TitleMaxChars} && length($Title) > $Param{TitleMaxChars} ) {
            $Title = substr( $Title, 0, $Param{TitleMaxChars} ) . '...';
        }
    }

    # set field link form config
    my $Link = $Param{DynamicFieldConfig}->{Config}->{Link} || '';

    
    if ($Param{DynamicFieldConfig}->{Config}->{StoreValue} && $Param{DynamicFieldConfig}->{Config}->{StoreValue} eq "1") {
    	$Key =~ s/^([^|]+)\|\|(.+)$/$1/;
    }
    $Link =~ s/%KEY%/$Key/g;

    my $Query = $Param{DynamicFieldConfig}->{Config}->{Query} || '';

    my $Data = {
        Value => $Value,
        Title => $Title,
        Link  => $Link,
	Query => $Query,
    };

    return $Data;
}

sub IsSortable {
    my ( $Self, %Param ) = @_;

    return 1;
}

sub SearchFieldRender {
    my ( $Self, %Param ) = @_;

    # take config from field config
    my $FieldConfig = $Param{DynamicFieldConfig}->{Config};
    my $FieldName   = 'Search_DynamicField_' . $Param{DynamicFieldConfig}->{Name};
    my $FieldLabel  = $Param{DynamicFieldConfig}->{Label};

    my $Value;

    my @DefaultValue;

    if ( defined $Param{DefaultValue} ) {
        my @DefaultValue = split /;/, $Param{DefaultValue};
    }

    # set the field value
    if (@DefaultValue) {
        $Value = \@DefaultValue;
    }

    # get the field value, this fuction is always called after the profile is loaded
    my $FieldValues = $Self->SearchFieldValueGet(
        %Param,
    );

    if ( defined $FieldValues ) {
        $Value = $FieldValues;
    }

    # check and set class if necessary
    my $FieldClass = 'DynamicFieldMultiSelect FromDB';

    # set PossibleValues
    my $SelectionData = $FieldConfig->{PossibleValues};

    # get historical values from database
    my $HistoricalValues = $Self->HistoricalValuesGet(%Param);

    # add historic values to current values (if they don't exist anymore)
    if ( IsHashRefWithData($HistoricalValues) ) {
        for my $Key ( keys %{$HistoricalValues} ) {
            if ( !$SelectionData->{$Key} ) {
                $SelectionData->{$Key} = $HistoricalValues->{$Key}
            }
        }
    }

    # use PossibleValuesFilter if defined
    $SelectionData = $Param{PossibleValuesFilter}
        if defined $Param{PossibleValuesFilter};

    my $HTMLString = $Param{LayoutObject}->BuildSelection(
        Data         => $SelectionData,
        Name         => $FieldName,
        SelectedID   => $Value,
        Translation  => $FieldConfig->{TranslatableValues} || 0,
        PossibleNone => 0,
        Class        => $FieldClass,
        Multiple     => 1,
        HTMLQuote    => 1,
    );

    # call EditLabelRender on the common backend
    my $LabelString = $Self->{BackendCommonObject}->EditLabelRender(
        DynamicFieldConfig => $Param{DynamicFieldConfig},
        FieldName          => $FieldName,
    );

    my $Data = {
        Field => $HTMLString,
        Label => $LabelString,
    };

    return $Data;
}

sub SearchFieldValueGet {
    my ( $Self, %Param ) = @_;

    my $Value;

    # get dynamic field value form param object
    if ( defined $Param{ParamObject} ) {
        my @FieldValues = $Param{ParamObject}
            ->GetArray( Param => 'Search_DynamicField_' . $Param{DynamicFieldConfig}->{Name} );

        $Value = \@FieldValues;
    }

    # otherwise get the value from the profile
    elsif ( defined $Param{Profile} ) {
        $Value = $Param{Profile}->{ 'Search_DynamicField_' . $Param{DynamicFieldConfig}->{Name} };
    }
    else {
        return;
    }

    if ( defined $Param{ReturnProfileStructure} && $Param{ReturnProfileStructure} eq 1 ) {
        return {
            'Search_DynamicField_' . $Param{DynamicFieldConfig}->{Name} => $Value,
        };
    }

    return $Value;

}

sub SearchFieldParameterBuild {
    my ( $Self, %Param ) = @_;

    # get field value
    my $Value = $Self->SearchFieldValueGet(%Param);

    my $DisplayValue;

    if ($Value) {
        if ( ref $Value eq 'ARRAY' ) {

            my @DisplayItemList;
            for my $Item ( @{$Value} ) {

                # set the display value
                my $DisplayItem = $Param{DynamicFieldConfig}->{Config}->{PossibleValues}->{$Item}
                    || $Item;

		$DisplayItem = 'yyy';

                if ( $Param{DynamicFieldConfig}->{Config}->{TranslatableValues} ) {

                    # translate the value
                    $DisplayItem = $Param{LayoutObject}->{LanguageObject}->Get($DisplayValue);
                }

                push @DisplayItemList, $DisplayItem;
            }

            # combine different values into one string
            $DisplayValue = join ' + ', @DisplayItemList;
        }
        else {

            # set the display value
            $DisplayValue = $Param{DynamicFieldConfig}->{PossibleValues}->{$Value};
            
            $DisplayValue = 'xxx';

            if ( $Param{DynamicFieldConfig}->{Config}->{TranslatableValues} ) {

                # translate the value
                $DisplayValue = $Param{LayoutObject}->{LanguageObject}->Get($DisplayValue);
            }
        }
    }

    # return search parameter structure
    return {
        Parameter => {
            Equals => $Value,
        },
        Display => $DisplayValue,
    };
}

sub StatsFieldParameterBuild {
    my ( $Self, %Param ) = @_;

    # set PossibleValues
    my $Values = $Param{DynamicFieldConfig}->{Config}->{PossibleValues};

    # get historical values from database
    my $HistoricalValues = $Self->{DynamicFieldValueObject}->HistoricalValueGet(
        FieldID   => $Param{DynamicFieldConfig}->{ID},
        ValueType => 'Text,',
    );

    # add historic values to current values (if they don't exist anymore)
    for my $Key ( keys %{$HistoricalValues} ) {
        if ( !$Values->{$Key} ) {
            $Values->{$Key} = $HistoricalValues->{$Key}
        }
    }

    # use PossibleValuesFilter if defined
    $Values = $Param{PossibleValuesFilter}
        if defined $Param{PossibleValuesFilter};

    return {
        Values             => $Values,
        Name               => $Param{DynamicFieldConfig}->{Label},
        Element            => 'DynamicField_' . $Param{DynamicFieldConfig}->{Name},
        TranslatableValues => $Param{DynamicFieldconfig}->{Config}->{TranslatableValues},
    };
}

sub CommonSearchFieldParameterBuild {
    my ( $Self, %Param ) = @_;

    my $Operator = 'Equals';
    my $Value    = $Param{Value};

    return {
        $Operator => $Value,
    };
}

sub ReadableValueRender {
    my ( $Self, %Param ) = @_;

    my $Value = defined $Param{Value} ? $Param{Value} : '';

    # set title as value after update and before limit
    my $Title = $Value;

    # cut strings if needed
    if ( $Param{ValueMaxChars} && length($Value) > $Param{ValueMaxChars} ) {
        $Value = substr( $Value, 0, $Param{ValueMaxChars} ) . '...';
    }
    if ( $Param{TitleMaxChars} && length($Title) > $Param{TitleMaxChars} ) {
        $Title = substr( $Title, 0, $Param{TitleMaxChars} ) . '...';
    }

    my $Data = {
        Value => $Value,
        Title => $Title,
    };

    return $Data;
}

sub TemplateValueTypeGet {
    my ( $Self, %Param ) = @_;

    my $FieldName = 'DynamicField_' . $Param{DynamicFieldConfig}->{Name};

    # set the field types
    my $EditValueType   = 'SCALAR';
    my $SearchValueType = 'ARRAY';

    # return the correct structure
    if ( $Param{FieldType} eq 'Edit' ) {
        return {
            $FieldName => $EditValueType,
            }
    }
    elsif ( $Param{FieldType} eq 'Search' ) {
        return {
            'Search_' . $FieldName => $SearchValueType,
            }
    }
    else {
        return {
            $FieldName             => $EditValueType,
            'Search_' . $FieldName => $SearchValueType,
            }
    }
}

sub IsAJAXUpdateable {
    my ( $Self, %Param ) = @_;

    return 1;
}

sub RandomValueSet {
    my ( $Self, %Param ) = @_;

    my $Value = int( rand(500) );

    my $Success = $Self->ValueSet(
        %Param,
        Value => $Value,
    );

    if ( !$Success ) {
        return {
            Success => 0,
        };
    }
    return {
        Success => 1,
        Value   => $Value,
    };
}

sub IsMatchable {
    my ( $Self, %Param ) = @_;

    return 1;
}

sub ObjectMatch {
    my ( $Self, %Param ) = @_;

    my $FieldName = 'DynamicField_' . $Param{DynamicFieldConfig}->{Name};

    # return false if not match
    if ( $Param{ObjectAttributes}->{$FieldName} ne $Param{Value} ) {
        return 0;
    }

    return 1;
}

sub PossibleValuesError {
    my ( $Self, $message, $displayerror) = @_;
    my %PossibleValuesError;
    my $ErrorMessage = '';
    $ErrorMessage = 'ERROR: '.$message if $displayerror;
    %PossibleValuesError = ( '-' => $ErrorMessage );
    return \%PossibleValuesError;
}

sub AJAXPossibleValuesGet {
    my ( $Self, %Param ) = @_;

    ## ENABLE FOR DEBUG: ##
    my $DEBUG = 9;
    
    ## set displayerror
    my $DISPLAYERRORS = $Param{DynamicFieldConfig}->{Config}->{DisplayErrors} || 0;

    use Data::Dumper;
    open ERRLOG, '>>/tmp/DF_'.$Param{DynamicFieldConfig}->{Name}.'.log' if $DEBUG;
    print ERRLOG "[AJAXPossibleValuesGet START]---------------------------------\n" if $DEBUG;

    my $query_needed = 0;

    my %PossibleValues;

    my @SQLParameters_values;
    my @SQLParameters_values_refs;

    # split Parameters from DynamicFieldConfig in an array:
    my @SQLParameters_keys = split(',', $Param{DynamicFieldConfig}->{Config}->{Parameters});

    # We create a mapping for the parameters:
    # %SQLParameters_hash = {
    #    Param1 => 'value1',
    #    Param2 => undef,
    # }
    my %SQLParameters_hash;
    for my $key (@SQLParameters_keys) {
        $SQLParameters_hash{$key} = undef;
    }


    #### Distinguish between real ajax request and 'first visualization'
   
=comment

considerations:
- we can distinguish if it is an ajax request or a 'first load' with the presence of $Param{ParamObject}->{Query}->{param}->{ElementChanged}.
- we can distinguish if it is a new Ticket or a Ticket editing with the presence of $Param{ParamObject}->GetParam( Param => 'TicketID')

on ticket editing,
	on 'first load', load take all @SQLParameters_values from the stored ticket information,
	on 'ajax request', take value from http arguments, if not present, take from ticket information.
on ticket creation,
	on 'first load', take values from http arguments,
	on 'ajax request' take values from http arguments,

so we can solve each requirement with following code:
	if ( there is stored ticket information ) fill sqlparameter_values with stored information
	if ( there are http argument values ) fill sqlparameter_values with http argument values overwriting stored information if present
		if ( a http argument was changed that the query depends on ) force_query = 1

	if (!force_query) take from cache if ( cache present )

=cut

    if ( scalar(@SQLParameters_keys) && $Param{ParamObject} && $Param{ParamObject}->GetParam( Param => 'TicketID') ) {
    	my %TicketInfo;
    	# get Ticket from cache:
    	if ($Param{LayoutObject}->{TicketObject}->{'Cache::GetTicket'.$Param{ParamObject}->GetParam( Param => 'TicketID')}{''}{1}) {
    		%TicketInfo = %{$Param{LayoutObject}->{TicketObject}->{'Cache::GetTicket'.$Param{ParamObject}->GetParam( Param => 'TicketID')}{''}{1}};
    	}
    	else {
                my $EncodeObject = Kernel::System::Encode->new(
                    ConfigObject => $Param{ParamObject}->{ConfigObject},
                );
                my $TimeObject = Kernel::System::Time->new(
                    ConfigObject => $Param{ParamObject}->{ConfigObject},
                    LogObject    => $Param{ParamObject}->{LogObject},
                );
                my $DBObject = Kernel::System::DB->new(
                    ConfigObject => $Param{ParamObject}->{ConfigObject},
                    EncodeObject => $EncodeObject,
                    LogObject    => $Param{ParamObject}->{LogObject},
                    MainObject   => $Param{ParamObject}->{MainObject},
                );
                my $TicketObject = Kernel::System::Ticket->new(
                    ConfigObject       => $Param{ParamObject}->{ConfigObject},
                    LogObject          => $Param{ParamObject}->{LogObject},
                    DBObject           => $DBObject,
                    MainObject         => $Param{ParamObject}->{MainObject},
                    TimeObject         => $TimeObject,
                    EncodeObject       => $EncodeObject,
                );
                %TicketInfo = $TicketObject->TicketGet(
                    TicketID      => $Param{ParamObject}->GetParam( Param => 'TicketID'),
                    DynamicFields => 1,         # Optional, default 0. To include the dynamic field values for this ticket on the return structure.
                    UserID        => 0,
                );
    	}

    	for my $key (@SQLParameters_keys) {
    		if ($key eq 'SelectedCustomerUser') {
    			$SQLParameters_hash{$key} = $TicketInfo{CustomerUserID};
    		}
    		else {
    			$SQLParameters_hash{$key} = $TicketInfo{$key};
    		}
    	}
    } 

    my %LinkTicketInfo;
    my %LinkTicketValues;
    if ( $Param{ParamObject} && $Param{ParamObject}->GetParam( Param => 'LinkTicketID') ) {
        if ($Param{LayoutObject}->{TicketObject}->{'Cache::GetTicket'.$Param{ParamObject}->GetParam( Param => 'LinkTicketID')}{''}{1}) {
            %LinkTicketInfo = %{$Param{LayoutObject}->{TicketObject}->{'Cache::GetTicket'.$Param{ParamObject}->GetParam( Param => 'LinkTicketID')}{''}{1}};
        } else {
            my $EncodeObject = Kernel::System::Encode->new(
               ConfigObject => $Param{ParamObject}->{ConfigObject},
           );
           my $TimeObject = Kernel::System::Time->new(
               ConfigObject => $Param{ParamObject}->{ConfigObject},
               LogObject    => $Param{ParamObject}->{LogObject},
           );
           my $DBObject = Kernel::System::DB->new(
               ConfigObject => $Param{ParamObject}->{ConfigObject},
               EncodeObject => $EncodeObject,
               LogObject    => $Param{ParamObject}->{LogObject},
               MainObject   => $Param{ParamObject}->{MainObject},
           );
           my $TicketObject = Kernel::System::Ticket->new(
               ConfigObject       => $Param{ParamObject}->{ConfigObject},
               LogObject          => $Param{ParamObject}->{LogObject},
               DBObject           => $DBObject,
               MainObject         => $Param{ParamObject}->{MainObject},
               TimeObject         => $TimeObject,
               EncodeObject       => $EncodeObject,
           );
           %LinkTicketInfo = $TicketObject->TicketGet(
               TicketID      => $Param{ParamObject}->GetParam( Param => 'LinkTicketID'),
               DynamicFields => 1,         # Optional, default 0. To include the dynamic field values for this ticket on the return structure.
               UserID        => 0,
           );
        }
        print ERRLOG "Got ticket id; performing query to get stored values\n" if $DEBUG;    

        #ATOR - get stored values in linked ticket
        my $query = 'SELECT value_text from dynamic_field_value WHERE object_id = ? AND field_id = ?';
        my $FieldID = $Param{DynamicFieldConfig}->{ID};
        my $ObjectID = $Param{ParamObject}->GetParam( Param => 'LinkTicketID');
        $Self->{DBObject}->Prepare(
                SQL => $query,
                #Bind => [ \$Param{ParamObject}->GetParam( Param => 'LinkTicketID'), \$Param{DynamicFieldConfig}->{ID} ],
                Bind => [\$ObjectID, \$FieldID],
        );
        my @row = $Self->{DBObject}->FetchrowArray();
        while (@row) { 
            my %Value;
            #check if value contains ||, if so split key=>value
            if ($row[0] =~ /\|\|/ ) {
                my @splitted = split('||', $row[0]);
                $Value{$splitted[0]} = $splitted[1];
            } else {
                $Value{$row[0]} = $row[0];
            }  
            %LinkTicketValues = ( %LinkTicketValues, %Value);
            #next row
            @row = $Self->{DBObject}->FetchrowArray();
            }
        #print ERRLOG "LinkTicketID : $FieldID\n";
    } 

    if ( $Param{ParamObject} && $Param{ParamObject}->{Query}->{param} ) {
    	# REAL AJAX REQUEST, TAKE PARAMS FROM AJAX REQUEST
            # for each parameter extract value from the ParamObject
            for my $key (@SQLParameters_keys) {
                print ERRLOG Dumper($Param{ParamObject}->{Query}->{param}) if $DEBUG;
                if ($Param{ParamObject}->{Query}->{param}->{$key} && $Param{ParamObject}->{Query}->{param}->{$key}[0]) {
                    $SQLParameters_hash{$key} = $Param{ParamObject}->{Query}->{param}->{$key}[0];
                }
                # if the changed Element is in the parameter list, update data
                if ($Param{ParamObject}->{Query}->{param}->{ElementChanged} && $key eq $Param{ParamObject}->{Query}->{param}->{ElementChanged}[0]) {
                    print ERRLOG '$Param{ParamObject}->{Query}->{param}->{ElementChanged}[0]' if $DEBUG;
                    print ERRLOG Dumper(\$Param{ParamObject}->{Query}->{param}->{ElementChanged}[0]) if $DEBUG;
                    $query_needed = 1;
<<<<<<< HEAD:src/trunk/Custom/Kernel/System/DynamicField/Backend/DropdownFromDB.pm
	            my @val = ( '+' );
                    $Param{ParamObject}->{Query}->{param}->{'DynamicField_'.$Param{DynamicFieldConfig}->{Name}} = \@val;
 	        }
=======
                    print ERRLOG '$Param{ParamObject}->{Query}->{param}->{ElementChanged}[0]' if $DEBUG;
                    print ERRLOG Dumper(\$Param{ParamObject}->{Query}->{param}->{ElementChanged}[0]) if $DEBUG;
                    my @val = ( '+' );
                    $Param{ParamObject}->{Query}->{param}->{'DynamicField_'.$Param{DynamicFieldConfig}->{Name}} = \@val;
                }
>>>>>>> 856da230201f9c802aa82ed3b2d4351cd0abb13a:src/Custom/Kernel/System/DynamicField/Backend/DropdownFromDB.pm
                else {
                }
            }
    } else {
        print ERRLOG "ParamObject DOES NOT EXIST!!\n" if $DEBUG;
    }
    

    # finally build the original array with only values:
    for my $key (@SQLParameters_keys) {
        # sometimes we got '<key>||<value>' string, so in that case extract key only:

        if ( ! $SQLParameters_hash{$key} ) {
            # if one parameter is undef, return empty Possible values;
            return $Self->PossibleValuesError('wrong number of parameters, please check settings. ('.$key.' is missing)', $DISPLAYERRORS);
        }

        $SQLParameters_hash{$key} =~ s/^([^|]+)\|\|(.+)$/$1/;

        print ERRLOG $SQLParameters_hash{$key}."\n\n" if $DEBUG;

        push(@SQLParameters_values, $SQLParameters_hash{$key});
        push(@SQLParameters_values_refs, \$SQLParameters_hash{$key});

    }

    if (!(($Param{DynamicFieldConfig}->{Config}->{Query} =~ tr/?//) eq scalar(@SQLParameters_values))) {
        return $Self->PossibleValuesError('wrong number of parameters, please check settings.', $DISPLAYERRORS);
    }

    my $PossibleValues_ref = $Self->{CacheObject}->Get(
        Type	=> 'Hash',
        Key	=> $Param{DynamicFieldConfig}->{Name} . join('', @SQLParameters_values),
    );

    if ($PossibleValues_ref) { # we got the values in cache
        %PossibleValues = %{ $PossibleValues_ref };
    }
    else {
        my $selected_parameter = $Param{ParamObject}->{Query}->{param}->{$Param{DynamicFieldConfig}->{Config}->{Parameters}}[0];
    
        # set none value if defined on field config
        if ( $Param{DynamicFieldConfig}->{Config}->{PossibleNone} ) {
            %PossibleValues = ( '' => '-' );
        }


    	# if no query specified quit:
        if ( !$Param{DynamicFieldConfig}->{Config}->{Query} || $Param{DynamicFieldConfig}->{Config}->{Query} eq '' ) {
            return $Self->PossibleValuesError('no query specified, please check settings.', $DISPLAYERRORS);
        }

        ### SET DEFAULT SETTINGS
        # set a default Separator
        if ( !$Param{DynamicFieldConfig}->{Config}->{Separator} ) {
            $Param{DynamicFieldConfig}->{Config}->{Separator} = ', ';
        }
        ### END SET DEFAULT SETTINGS

        my @row;
        my $sth;
        my $dbh;

        # use local DB Object if no DBI string is specified.
        if ( !$Param{DynamicFieldConfig}->{Config}->{DBIstring} ) {
            $Self->{DBObject}->Prepare(
                SQL => $Param{DynamicFieldConfig}->{Config}->{Query},
                Bind => \@SQLParameters_values_refs,
            );

            #fetch first row
            @row = $Self->{DBObject}->FetchrowArray();

        } else {
            $dbh = DBI->connect($Param{DynamicFieldConfig}->{Config}->{DBIstring}, $Param{DynamicFieldConfig}->{Config}->{DBIuser}, $Param{DynamicFieldConfig}->{Config}->{DBIpass},
                              { PrintError => 0, AutoCommit => 0, HandleError => \&PossibleValuesError }) or return $Self->PossibleValuesError("could not connect to DB: $DBI::errstr", $DISPLAYERRORS);
        
            $dbh->{'mysql_enable_utf8'} = 1;
    
            $sth = $dbh->prepare($Param{DynamicFieldConfig}->{Config}->{Query});
            $sth->execute( @SQLParameters_values );
    
            # fetch first row
            @row = $sth->fetchrow_array;        
        }

        print ERRLOG ":::Extracted from DB:::\n" if $DEBUG;
        print ERRLOG Dumper(@row) if $DEBUG;
        print ERRLOG "::::::::::::::::::::::::::\n" if $DEBUG;
        close ERRLOG if $DEBUG;

        # cicle fetched rows from DB
        while (@row) {
            my $line = '';
            my $firstRow = 0;
            for my $col (@row) {
                if (!utf8::is_utf8($col)) {
                    utf8::decode( $col );
                }
                if (!$firstRow) { # skip first row 
                    $firstRow = 1;
            	next;
                }
                $line .= $col.$Param{DynamicFieldConfig}->{Config}->{Separator};
            }

            $line = substr($line, 0, -1 * length($Param{DynamicFieldConfig}->{Config}->{Separator}));
            if ($Param{DynamicFieldConfig}->{Config}->{StoreValue} && $Param{DynamicFieldConfig}->{Config}->{StoreValue} eq "1") {
                %PossibleValues = ( %PossibleValues, $row[0]."||".$line => $line);
            }
            else {
                %PossibleValues = ( %PossibleValues, $row[0] => $line );
            }

            # fetch new row depending on DB connection type
            if ( !$Param{DynamicFieldConfig}->{Config}->{DBIstring} ) {
                @row = $Self->{DBObject}->FetchrowArray();
            }
            else {
                @row = $sth->fetchrow_array;
		if (!@row) {
                    $dbh->disconnect;
                }
            }
        }

        # put all in the cache:
	
        $Self->{CacheObject}->Set(
            Type	=> 'Hash',
            Key		=> $Param{DynamicFieldConfig}->{Name} . join('', @SQLParameters_values),
            Value	=> \%PossibleValues,
            TTL		=> $Param{DynamicFieldConfig}->{CacheTTL} || 360,
        );
    }

    # add values from Linked Ticket as possible values (so it will be selected on ticket split)
    %PossibleValues = (%PossibleValues, %LinkTicketValues);

    $Param{DynamicFieldConfig}->{Config}->{PossibleValues} = \%PossibleValues;
    # retrun the possible values hash as a reference
    return \%PossibleValues;
}

sub HistoricalValuesGet {
    my ( $Self, %Param ) = @_;

    # get historical values from database
    my $HistoricalValues = $Self->{DynamicFieldValueObject}->HistoricalValueGet(
        FieldID   => $Param{DynamicFieldConfig}->{ID},
        ValueType => 'Text',
    );

<<<<<<< HEAD:src/trunk/Custom/Kernel/System/DynamicField/Backend/DropdownFromDB.pm
    # BINI - 27.03.2013
    #
    # Remove "<val>||" from historical values used in search form
    #
    if ($Param{DynamicFieldConfig}->{Config}->{StoreValue} eq "1") {
      if ( IsHashRefWithData($HistoricalValues) ) {
        for my $Key ( sort keys %{$HistoricalValues} ) {
            $HistoricalValues->{$Key} =~ s/^([^|]+)\|\|(.+)$/$2/;
        }
      }
    }
    # BINI
=======
    # BINI - 27.03.2013                                                                                                                                      
    #                                                                                                                                                        
    # Remove "<key >||" from historical values used in search form                                                                                            
    #                                                                                                                                                        
    if ($Param{DynamicFieldConfig}->{Config}->{StoreValue} eq "1") {                                                                                         
      if ( IsHashRefWithData($HistoricalValues) ) {                                                                                                          
        for my $Key ( sort keys %{$HistoricalValues} ) {                                                                                                     
            $HistoricalValues->{$Key} =~ s/^([^|]+)\|\|(.+)$/$2/;                                                                                            
        }                                                                                                                                                    
      }                                                                                                                                                      
    }                                                                                                                                                        
    # BINI                                                                                                                                                   
>>>>>>> 856da230201f9c802aa82ed3b2d4351cd0abb13a:src/Custom/Kernel/System/DynamicField/Backend/DropdownFromDB.pm
    #

    # retrun the historical values from database
    return $HistoricalValues;
}

sub ValueLookup {
    my ( $Self, %Param ) = @_;

    my $Value = defined $Param{Key} ? $Param{Key} : '';

<<<<<<< HEAD:src/trunk/Custom/Kernel/System/DynamicField/Backend/DropdownFromDB.pm
    # get real values
    my $PossibleValues = $Param{DynamicFieldConfig}->{Config}->{PossibleValues};

    if ($Value) {

        # check if there is a real value for this key (otherwise keep the key)
        if ( $Param{DynamicFieldConfig}->{Config}->{PossibleValues}->{$Value} ) {

            # get readeable value
            $Value = $Param{DynamicFieldConfig}->{Config}->{PossibleValues}->{$Value};

            # check if translation is possible
            if (
                defined $Param{LanguageObject}
                && $Param{DynamicFieldConfig}->{Config}->{TranslatableValues}
                )
            {

                # translate value
                $Value = $Param{LanguageObject}->Get($Value);
            }
        }
    }
=======
    # remove the '<key>||' if present
    $Value =~ s/^([^|]+)\|\|(.+)$/$2/; 
>>>>>>> 856da230201f9c802aa82ed3b2d4351cd0abb13a:src/Custom/Kernel/System/DynamicField/Backend/DropdownFromDB.pm

    return $Value;
}

1;

=back

=head1 TERMS AND CONDITIONS

This software is part of the OTRS project (L<http://otrs.org/>).

This software comes with ABSOLUTELY NO WARRANTY. For details, see
the enclosed file COPYING for license information (AGPL). If you
did not receive this file, see L<http://www.gnu.org/licenses/agpl.txt>.

=cut

=head1 VERSION

$$

=cut
