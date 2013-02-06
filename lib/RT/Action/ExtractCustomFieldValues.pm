package RT::Action::ExtractCustomFieldValues;
require RT::Action;

use strict;
use warnings;
use XML::XPath;

use base qw(RT::Action);

our $VERSION = 2.99_01;

sub Describe {
    my $self = shift;
    return ( ref $self );
}

sub Prepare {
    return (1);
}

sub FirstAttachment {
    my $self = shift;
    return $self->TransactionObj->Attachments->First;
}

sub Queue {
    my $self = shift;
    return $self->TicketObj->QueueObj->Id;
}

sub TemplateContent {
    my $self = shift;
    return $self->TemplateObj->Content;
}

sub TemplateConfig {
    my $self = shift;

    my ($content, $error) = $self->TemplateContent;
    if (!defined($content)) {
        return (undef, $error);
    }

    my $Separator = '\|';
    my @lines = split( /[\n\r]+/, $content);
    my @results;
    for (@lines) {
        chomp;
        next if /^#/;
        next if /^\s*$/;
        if (/^Separator=(.+)$/) {
            $Separator = $1;
            next;
        }
        my %line;
        @line{qw/CFName Field Match PostEdit Options/}
            = split(/$Separator/);
        $_ = '' for grep !defined, values %line;
        push @results, \%line;
    }
    return \@results;
}


sub Commit {
    my $self            = shift;
    return 1 unless $self->FirstAttachment;

    my ($config_lines, $error) = $self->TemplateConfig;

    return 0 if $error;

    for my $config (@$config_lines) {
        my %config = %{$config};

        $RT::Logger->debug( "Looking to extract: "
                . join( " ", map {"$_=$config{$_}"} sort keys %config ) );

        my $cf;
        $cf = $self->LoadCF( Name => $config{CFName} )
            if $config{CFName};

        #This is the callback executed when the search is for a single CF via regex.
        my $__cb = sub {
            my $content = shift;
            return 0 unless $content =~ /($config{Match})/m;

        $self->ProcessCF(
                %config,
                CustomField => $cf,
                Value       => $2 || $1,
            );
            return 1;
        };

        #This is the callback executed when the search is for multiple CFs via regex.
        my $__cb_multi = sub {
            my $content = shift;
            my $found = 0;
            while ( $content =~ /$config{Match}/mg ) {
                my ( $cfname, $value ) = ( $1, $2 );
                $cf = $self->LoadCF( Name => $cfname, Quiet => 1 );
                next unless $cf;
                $found++;
                $self->ProcessCF(
                    %config,
                    CustomField => $cf,
                    Value       => $value
                );
            }
            return $found;
        };

        #This is the callback executed when the search is via xml, multi or not.
        my $__cb_xml = sub {
            my $content = shift;
        
            $RT::Logger->debug( "Requested xpath match instead of regex" );
            #first we have to get the search contents
            my $xp = XML::XPath->new( xml => $config{Match} );

            # the Match content will look like one of these:
            #
            # /path/to/cf/value                <- an xpath statement
            #
            #       -or-
            #
            # <find>                                <-a tiny xml doc
            #     <root>/path/to/chunk</root>         (probably not
            #     <name>/path/to/cfname</name>         linewrapped)
            #     <value>/path/to/value</value>
            # </find>
   
            my ($rootpath, $namepath, $valuepath) = 0;

            if ($config{Options} =~ /\*/ ) {
                eval {
                    $rootpath = $xp->findvalue('/find/root');
                    $namepath = $xp->findvalue('/find/name');
                    $valuepath = $xp->findvalue('/find/value');
                    $RT::Logger->debug( "Found search paths: "
                    . join( "\n", ($rootpath, $namepath, $valuepath) ) );
                    1;
                } or do {
                    #if XML::XPath::XMLParse chokes on the document, that means it
                    #probably isn't xml. The user has made some sort of mistake.
                    $RT::Logger->warning( "You asked for an xml multimatch, but the search string wasn't xml. I give up." );
                    return 0;
                };	
            } else {
                $rootpath = $config{Match};
                $RT::Logger->debug( "Found single search path: $rootpath" );
            }

            #ok now the real search
            $xp->set_xml($content);
            my $search_result = $xp->find($rootpath);
            return 0 unless $search_result;

            $RT::Logger->debug( "Search yielded " . $search_result->size . " matches." );
            if ( $namepath && $valuepath && 
                 $search_result->size > 1 ) {
                $RT::Logger->debug( "Multi-results found: $search_result" );
                foreach my $node ($search_result->getnodelist()) {
                    my ($cfname, $val);
                    eval {
                        $cfname = $xp->find($namepath, $node);
                        $val = $xp->find($valuepath, $node);
                        $RT::Logger->debug( "Found name: $cfname and val: $val " );
                        1;
                    } or do {
                        return 0;
                    };
                    $cf = $self->LoadCF( Name => $cfname, Quiet => 1 );
                    next unless $cf;
                    $val = join(',', $val->get_nodelist) if ($val->isa('XML::XPath::NodeSet'));
                    $self->ProcessCF(
                        %config,
                        CustomField => $cf,
                        Value       => $val,
                    );
                }
            }
            #$cf will be defined by the Commit sub in whose context this cb is run.
            elsif ( $cf && ( $search_result->size == 1 ) ) {
                $self->ProcessCF(
                    %config,
                    CustomField => $cf,
                    Value       => $search_result->string_value(),
                );

            }
            return 0;
        };



        #Order matters! 
	my $callback = $__cb;
        $callback = $__cb_multi if $config{Options} =~ /\*/;
        $callback = $__cb_xml if $config{Options} =~ /x/;

        $self->FindContent(
            %config,
            Callback    => $callback,
        );
    }
    return (1);
}

sub LoadCF {
    my $self = shift;
    my %args            = @_;
    my $CustomFieldName = $args{Name};
    $RT::Logger->debug( "Looking for CF $CustomFieldName");

    # We do this by hand instead of using LoadByNameAndQueue because
    # that can find disabled queues
    my $cfs = RT::CustomFields->new($RT::SystemUser);
    $cfs->LimitToGlobalOrQueue($self->Queue);
    $cfs->Limit(
        FIELD         => 'Name',
        VALUE         => $CustomFieldName,
        CASESENSITIVE => 0
    );
    $cfs->RowsPerPage(1);

    my $cf = $cfs->First;
    if ( $cf && $cf->id ) {
        $RT::Logger->debug( "Found CF id " . $cf->id );
    } elsif ( not $args{Quiet} ) {
        $RT::Logger->error( "Couldn't load CF $CustomFieldName!");
    }

    return $cf;
}

sub FindContent {
    my $self = shift;
    my %args = @_;
    if ( lc $args{Field} eq "body" ) {
        my $Attachments  = $self->TransactionObj->Attachments;
        my $LastContent  = '';
        my $AttachmentCount = 0;

        my @list = @{ $Attachments->ItemsArrayRef };
        while ( my $Message = shift @list ) {
            $AttachmentCount++;
            $RT::Logger->debug( "Looking at attachment $AttachmentCount, content-type "
                                    . $Message->ContentType );
            my $ct = $Message->ContentType;
            unless ( $ct =~ m!^(text/plain|message|text$)!i ) {
                # don't skip one attachment that is text/*
                next if @list > 1 || $ct !~ m!^text/!;
            }

            my $content = $Message->Content;
            next unless $content;
            next if $LastContent eq $content;
            $RT::Logger->debug( "Examining content of body" );
            $LastContent = $content;
            $args{Callback}->( $content );
        }
    } elsif ( lc $args{Field} eq 'headers' ) {
        my $attachment = $self->FirstAttachment;
        $RT::Logger->debug( "Looking at the headers of the first attachment" );
        my $content = $attachment->Headers;
        return unless $content;
        $RT::Logger->debug( "Examining content of headers" );
        $args{Callback}->( $content );
    } else {
        my $attachment = $self->FirstAttachment;
        $RT::Logger->debug( "Looking at $args{Field} header of first attachment" );
        my $content = $attachment->GetHeader( $args{Field} );
        return unless defined $content;
        $RT::Logger->debug( "Examining content of header" );
        $args{Callback}->( $content );
    }
}

sub ProcessCF {
    my $self = shift;
    my %args = @_;

    return $self->PostEdit(%args)
        unless $args{CustomField};

    my @values = ();
    if ( $args{CustomField}->SingleValue() ) {
        push @values, $args{Value};
    } else {
        @values = split( ',', $args{Value} );
    }

    foreach my $value ( grep defined && length, @values ) {
        $value = $self->PostEdit(%args, Value => $value );
        next unless defined $value && length $value;

        $RT::Logger->debug( "Found value for CF: $value");
        my ( $id, $msg ) = $self->TicketObj->AddCustomFieldValue(
            Field             => $args{CustomField},
            Value             => $value,
            RecordTransaction => $args{Options} =~ /q/ ? 0 : 1
        );
        $RT::Logger->info( "CustomFieldValue ("
                . $args{CustomField}->Name
                . ",$value) added: $id $msg" );
    }
}

sub PostEdit {
    my $self = shift;
    my %args = @_;

    return $args{Value} unless $args{Value} && $args{PostEdit};

    $RT::Logger->debug( "Running PostEdit for '$args{Value}'");
    my $value = $args{Value};
    local $_  = $value;    # backwards compatibility
    local $@;
    eval( $args{PostEdit} );
    $RT::Logger->error("$@") if $@;
    return $value;
}

1;
