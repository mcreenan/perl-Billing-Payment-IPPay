package Billing::Payment::IPPay;

use strict;
use warnings;

use Carp qw( confess croak );
use LWP::UserAgent;
use Switch;
use XML::LibXML;

my %endpoint = (
    live => 'https://gateway08.ippay.com/ippay/',
    test => 'https://testgtwy.ippay.com/ippay/',
);
my @origins = ( 'INTERNET', 'RECURRING', 'POS', 'PHONE ORDER', 'MAIL ORDER', );
my @transaction_types = (
    'SALE',        'AUTHONLY',    'CAPT',     'VOID',
    'ENQ',         'CREDIT',      'CHECK',    'REVERSAL',
    'VOIDACH',     'REVERSEAUTH', 'TOKENIZE', 'PARTIALREVERSE',
    'INCREMENTAL', 'PING',        'ACK'
);
my @known_transaction_fields = (
    'ABA',              'ACH',
    'AccountNumber',    'AccountType',
    'ActionCode',       'Address',
    'Approval',         'BillingAddress',
    'BillingCity',      'BillingCountry',
    'BillingPhone',     'BillingPostalCode',
    'BillingStateProv', 'CardExpMonth',
    'CardExpYear',      'CardName',
    'CardNum',          'CardStartMonth',
    'CardStartYear',    'CAVV',
    'CheckNumber',      'City',
    'Country',          'CustomerPO',
    'CVV2',             'DispositionType',
    'ECI',              'Email',
    'FeeAmount',        'IndustryInfo',
    'ipTransId',        'Issue',
    'OrderNumber',      'Origin',
    'Password',         'Phone',
    'RoutingCode',      'Scrutiny',
    'SEC',              'ShippingMethod',
    'ShippingName',     'StateProv',
    'TaxAmount',        'TerminalID',
    'TotalAmount',      'Token',
    'Track1',           'Track2',
    'TransactionID',    'TransactionType',
    'UDField1',         'UDField2',
    'UDField3',         'UserHost',
    'UserIPAddress',    'Verification',
    'XID',
);
my @ach_known_attributes = ( 'Tokenize', 'Type', 'SEC', );
my @ach_known_fields =
  ( 'AccountNumber', 'ABA', 'CheckNumber', 'Token', 'Scrutiny' );

sub new {
    my $class = shift;
    my %attrs = ref $_[0] ? %{ $_[0] } : @_;

    $attrs{endpoint} = $attrs{test} ? $endpoint{test} : $endpoint{live};
    defined $attrs{terminal_id}
      or confess 'terminal_id is a required attribute';

    if (    defined $attrs{debug}
        and $attrs{debug}
        and not defined $attrs{debug_fn} )
    {
        $attrs{debug_fn} = sub {
            my ($level, $message) = @_;
            printf "[%s] %s\n", $level, $message;
        };
    }

    return bless \%attrs, $class;
}

sub submit_transaction {
    my ( $self, $data ) = @_;

    $data->{TerminalID} ||= $self->{terminal_id};
    $data->{MerchantID} ||= $self->{terminal_id};
    $data->{Password}   ||= $self->{password};
    $data->{Origin}     ||= 'INTERNET';
    $self->_validate_transaction($data);

    # IPPay expects the total amount to be in whole cents (e.g. 100 instead of
    # 1.00)
    if ( exists $data->{TotalAmount} ) {
        $data->{TotalAmount} = int( $data->{TotalAmount} * 100 );
    }
    if ( exists $data->{FeeAmount} ) {
        $data->{FeeAmount} = int( $data->{FeeAmount} * 100 );
    }
    if ( exists $data->{TaxAmount} ) {
        $data->{TaxAmount} = int( $data->{TaxAmount} * 100 );
    }

    # This will generate an XML document with a root node named ippay
    # and child nodes (e.g. TerminalID) that each contain a single text node
    my $payload = $self->_build_xml_payload($data);

    my $lwp =
      LWP::UserAgent->new( agent => 'Billing::Payment::IPPay Perl Module' );
    my $http_response = $lwp->post(
        sprintf( '%s', $self->{endpoint} ),
        Content_Type => 'text/xml',
        Content      => $payload,
    );

    $self->_debug('DEBUG', "Test Mode: " . ($self->{test} ? "Yes" : "No"));
    $self->_debug('DEBUG', "Endpoint: " . $self->{endpoint});
    $self->_debug('DEBUG', "Request Payload:\n$payload\n");
    $self->_debug('DEBUG', "Response Payload:\n" . $http_response->content . "\n");

    # IPPay's TOKENIZE transaction returns the ippayResponse node with different
    # capitalization than all other calls
    my $root_node_name =
      $data->{TransactionType} eq 'TOKENIZE'
      ? 'IPPayResponse'
      : 'ippayResponse';

    if ( $http_response->code =~ /^2/x ) {
        my $xml_parser   = XML::LibXML->new;
        my $xml_document = $xml_parser->parse_string( $http_response->content );
        my $response_code =
          $xml_document->findvalue("$root_node_name/ActionCode");

        if ( $response_code ne '000' ) {
            return {
                success    => 0,
                http_code  => $http_response->code,
                error_code => $response_code,
                body       => $http_response->content,
                error => $xml_document->findvalue("$root_node_name/ErrMsg"),
            };
        }

        my %response_data = map {
            $_->nodeName => $_->textContent
        } $xml_document->findnodes("$root_node_name/*");

        return {
            success   => 1,
            http_code => $http_response->code,
            body      => $http_response->content,
            data      => \%response_data,
        };
    }
    else {
        return {
            success   => 0,
            http_code => $http_response->code,
            body      => $http_response->error_as_HTML,
            error     => 'Unexpected HTTP response',
        };
    }
}

sub authonly {
    my ( $self, $data ) = @_;

    for my $required_field (
        qw(CardNum CardExpMonth CardExpYear TotalAmount) )
    {
        confess "Missing required field: $required_field"
          if not exists $data->{$required_field}
              or not defined $data->{$required_field};
        $self->_validate_data( $required_field,
            $data->{$required_field} );
    }

    $data->{TransactionType} = 'AUTHONLY';
    return $self->submit_transaction($data);
}

sub capture {
    my ( $self, $data ) = @_;

    confess "Missing required field: TransactionID"
      if not exists $data->{TransactionID};

    if ( exists $data->{Approval} ) {
        for my $required_field (
            qw(CardNum CardExpMonth CardExpYear TotalAmount))
        {
            confess "Missing required field: $required_field"
              if not exists $data->{$required_field}
                  or not defined $data->{$required_field};
        }
    }

    $data->{TransactionType} = 'CAPT';
    my $ippay_response = $self->submit_transaction($data);
    if (!$ippay_response->{success} && $ippay_response->{error_code} eq '025') {
        confess "You must capture a previously authorized transaction only";
    }

    return $ippay_response;
}

sub credit {
    my ( $self, $data ) = @_;

    confess "Missing required field: TransactionID"
      if not exists $data->{TransactionID};

    if ( exists $data->{Approval} ) {
        for my $required_field (
            qw(CardNum CardExpMonth CardExpYear TotalAmount))
        {
            confess "Missing required field: $required_field"
              if not exists $data->{$required_field}
                  or not defined $data->{$required_field};
        }
    }

    $data->{TransactionType} = 'CAPT';
    my $ippay_response = $self->submit_transaction($data);
    if (!$ippay_response->{success} && $ippay_response->{error_code} eq '025') {
        confess "You must capture a previously authorized transaction only";
    }

    return $ippay_response;
}

sub check {
    my ( $self, $data ) = @_;

    for my $required_field (
        qw(CardName TotalAmount FeeAmount ACH))
    {
        confess "Missing required field: $required_field"
          if not exists $data->{$required_field}
              or not defined $data->{$required_field};
    }
    if (ref $data->{ACH} eq 'HASH') {
        for my $required_ach_field ( qw(Type SEC) ) {
            confess "Missing required ACH field: $required_ach_field"
              if not exists $data->{ACH}->{$required_ach_field}
                  or not defined $data->{ACH}->{$required_ach_field};
        }
    }
    else {
        croak 'ACH field must be a HASH (is instead a '
          . (ref $data->{ACH}) . ')';
    }

    $data->{TransactionType} = 'CHECK';
    my $ippay_response = $self->submit_transaction($data);
    return $ippay_response;
}

sub enq {
    my ( $self, $data ) = @_;

    for my $required_field (
        qw(TransactionID))
    {
        confess "Missing required field: $required_field"
          if not exists $data->{$required_field}
              or not defined $data->{$required_field};
    }

    $data->{TransactionType} = 'VOID';
    my $ippay_response = $self->submit_transaction($data);
    return $ippay_response;
}

sub ping {
    my ( $self ) = @_;

    my $data = {
        TransactionType => 'PING',
    };
    my $ippay_response = $self->submit_transaction($data);
    return $ippay_response;
}

sub reversal {
    my ( $self, $data ) = @_;

    for my $required_field (
        qw(TransactionID))
    {
        confess "Missing required field: $required_field"
          if not exists $data->{$required_field}
              or not defined $data->{$required_field};
    }

    $data->{TransactionType} = 'REVERSAL';
    my $ippay_response = $self->submit_transaction($data);
    return $ippay_response;
}


sub sale {
    my ( $self, $data ) = @_;

    for my $required_field (
        qw(CardNum CardExpMonth CardExpYear TotalAmount) )
    {
        confess "Missing required field: $required_field"
          if not exists $data->{$required_field}
              or not defined $data->{$required_field};
        $self->_validate_data( $required_field,
            $data->{$required_field} );
    }

    $data->{TransactionType} = 'SALE';
    my $ippay_response = $self->submit_transaction($data);
    return $ippay_response;
}

sub tokenize {
    my ( $self, $data ) = @_;

    for my $required_field (
        qw(CardNum CardExpMonth CardExpYear))
    {
        confess "Missing required field: $required_field"
          if not exists $data->{$required_field}
              or not defined $data->{$required_field};
    }

    $data->{TransactionType} = 'TOKENIZE';
    my $ippay_response = $self->submit_transaction($data);
    return $ippay_response;
}

sub void {
    my ( $self, $data ) = @_;

    for my $required_field (
        qw(TransactionID TotalAmount))
    {
        confess "Missing required field: $required_field"
          if not exists $data->{$required_field}
              or not defined $data->{$required_field};
    }

    $data->{TransactionType} = 'VOID';
    my $ippay_response = $self->submit_transaction($data);
    return $ippay_response;
}

sub voidach {
    my ( $self, $data ) = @_;

    for my $required_field (
        qw(TransactionID TotalAmount))
    {
        confess "Missing required field: $required_field"
          if not exists $data->{$required_field}
              or not defined $data->{$required_field};
    }

    $data->{TransactionType} = 'VOIDACH';
    my $ippay_response = $self->submit_transaction($data);
    return $ippay_response;
}



#===============================================================================
# Internal methods
#===============================================================================

sub _validate_transaction {
    my ( $self, $data ) = @_;

    $data->{TransactionType} = uc $data->{TransactionType};
    $data->{Origin}          = uc $data->{Origin};

    grep { $_ eq $data->{TransactionType} } @transaction_types
      or confess "Invalid transaction type: $data->{TransactionType}";
    grep { $_ eq $data->{Origin} } @origins
      or confess "Invalid transaction type: $data->{Origin}";

    exists $data->{TerminalID}
      or confess "Missing required field: TerminalID";

    return 1;
}

sub _validate_data {
    my ( $self, $data_identifier, $data_value ) = @_;

    switch ($data_identifier) {
        case 'CardExpMonth' {
            $data_value =~ m/^([1-9]|1[0-2])$/x
              or confess "Invalid card expiration month";
        }
        case 'CardExpYear' {
            $data_value =~ m/^\d\d$/x
              or confess "Invalid card expiration year";
        }
    }

    return 1;
}

# This method assumes validation has been done on the data passed in first
sub _build_xml_payload {
    my ( $self, $data ) = @_;

    my $xml_document = XML::LibXML::Document->createDocument;
    my $root_node    = $xml_document->createElement('ippay');
    $xml_document->setDocumentElement($root_node);

    for my $field_name (@known_transaction_fields) {
        $self->_debug('DEBUG', "Checking for known field: $field_name");
        next if not defined $data->{$field_name};

        my $child_node = $xml_document->createElement($field_name);

        switch ($field_name) {
            case 'ACH' {
                croak 'ACH field must be a HASH'
                  if ref $data->{$field_name} ne 'HASH';

                # Add ACH attributes, given known attribute names
                for my $ach_attribute_name (@ach_known_attributes) {
                    $self->_debug( 'DEBUG',
                        "Checking for known ach attribute: $ach_attribute_name"
                    );
                    if ( exists $data->{ACH}->{$ach_attribute_name} ) {
                        $self->_debug( 'DEBUG',
                            "Found attribute $ach_attribute_name" );
                        $child_node->setAttribute( $ach_attribute_name,
                            $data->{ACH}->{$ach_attribute_name} );
                    }
                }

                # Add ACH child fields
                for my $ach_field (@ach_known_fields) {
                    $self->_debug( 'DEBUG',
                        "Checking for known ach field: $ach_field" );
                    if ( exists $data->{ACH}->{$ach_field} ) {
                        $self->_debug( 'DEBUG', "Found ACH field $ach_field" );
                        my $ach_child_node =
                          $xml_document->createElement($ach_field);
                        $ach_child_node->appendText(
                            $data->{ACH}->{$ach_field} );
                        $child_node->appendChild($ach_child_node);
                    }
                }
            }
            case 'IndustryInfo' {
                $child_node->setAttribute( 'Type',
                    $data->{IndustryInfo}->{Type} );
            }
            else {
                $child_node->appendText( $data->{$field_name} );
            }
        }

        $root_node->appendChild($child_node);
    }

    return $xml_document->toString;
}

sub _debug {
    my ($self, $level, $message) = @_;

    return if not defined $self->{debug} or not $self->{debug};
    $self->{debug_fn}->( $level, $message );

    return 1;
}

1;

__END__

=head1 NAME

Billing::Payment::IPPay - IPPay Payment Provider

=head1 SYNOPSIS

    use Billing::Payment::IPPay;

    # Create instance in test mode (uses ippay's test gateway)
    my $ippay = Billing::Payment::IPPay->new(
        test        => 1,
        terminal_id => 'TESTTERMINAL',
    );

    # Enable debugging with a custom debug handler
    my $ippay = Billing::Payment::IPPay->new(
        test        => 1,
        terminal_id => 'TESTTERMINAL',
        debug       => 1,
        debug_fn    => sub {
            my ($level, $message) = @_;
            printf "[%s] %s\n", $level, $message;
        },
    );

=head1 DESCRIPTION

Light wrapper around the IPPay REST/XML API

Provides methods for each Transaction Type as well as building the request XML payload
and parsing the response XML payload.

=head1 METHODS

=head2 Constructor

=head3 Billing::Payment::IPPay->new( ... )

This class method accepts the following class parameters:

=over 4

=item terminal_id

TerminalID value supplied by IPPay for your Merchant Account.

=item test

Use IPPay's test gateway.

=item debug

Enable debug information to be output or captured.

See L<debug_fn>

=item debug_fn

A function that accepts 2 parameters: level, message.

If you pass this, any debug message is sent to this function instead of printed
to STDOUT.

=back

=head2 Helper Methods

All helper methods return a hash with the following structure:

    {
        success    => 0|1,
        http_code  => ...,    # HTTP Response Code from IPPay
        error_code => ...,    # Only set if success = 0. Same as "ActionCode" value
                              #   in IPPay XML Response
        error      => ...,    # Friendly error message if success = 0, usually
                              #   comes directly from IPPay
        body       => ...,    # Raw HTTP request body (XML)
        data       => { ... } # XML-parsed list of data returned by IPPay
                              #   Example keys:
                              #   ActionCode
                              #   ResultText
                              #   ErrMsg
    }

=head3 authonly

Submits an authorization only (AUTHONLY) transaction.

=head4 Required Fields

=over 4

=item CardNum

16 digit credit card number.

=item CardExpMonth

2 digit expiration month.

=item CardExpYear

2 digit expiration year.

=item TotalAmount

Total amount to authorize, as a decimal value (e.g. 12.99).

=back

=head4 Usage

    my $response = $ippay->authonly(
        {
            CardNum      => '4000300020001000',
            CardExpMonth => '11',
            CardExpYear  => '14',
            TotalAmount  => 49.00,
        }
    );

    $response->{success}
      ? printf "OK (Transaction ID: %s)", $response->{data}->{TransactionID}
      : printf "FAILED (%s)", $response->{error};

=head3 capture

Submits a capture (CAPT) transaction, which captures a previous authorization 
request.

=head4 Required Fields

=over 4

=item TransactionID

Transaction ID from previous authonly transaction.

=back

=head4 Usage

    my $response = $ippay->capture(
        {
            TransactionID => '<Transaction ID>',
        }
    );

    $response->{success}
      ? printf "OK"
      : printf "FAILED (%s)", $response->{error};

=head3 credit

Issue a credit to refund a previous transaction.

=head4 Required Fields

=over 4

=item TransactionID

Transaction ID from previous capture or sale transaction.

=back

=head4 Usage

    my $response = $ippay->credit(
        {
            TransactionID => '<Transaction ID>',
        }
    );

    $response->{success}
      ? printf "OK"
      : printf "FAILED (%s)", $response->{error};

=head3 check

Charge a checking or savings account.

=head4 Required Fields

=over 4

=item CardName

Name for the account.

=item TotalAmount

Total amount to be charged, as a decimal dollar value (e.g. 14.95).

=item FeeAmount

Fee to charge for use of checking or savings account.

B<Note>: This charge is B<on top of> the TotalAmount value. If you specify 14.95
for TotalAmount and 1.00 for FeeAmount, the account is charged 15.95 in total.

=item ACH

Hash containing information about the checking or savings account.

=over 8

=item Type (required)

CHECKING or SAVINGS

=item AccountNumber (required)

Account number for the checking or savings account to be charged.

=item ABA (required)

Routing number associated with the checking or savings account to be charged.

Defaults to 0.

=item Tokenize

Whether or not to create and return a token associated with the checking or
savings account. If enabled, a I<TokenID> field will be returned in the
response.

=item SEC

Type of security to use

=item CheckNumber

Number on a check if checking account.

=back

=back

=head4 Usage

    my $response = $ippay->check(
        {
            CardName    => 'Test Card',
            TotalAmount => 49.00,
            FeeAmount   => 1.00,
            ACH         => {
                Type          => 'SAVINGS',
                Tokenize      => 'true',
                SEC           => 'PPD',
                AccountNumber => '11111999',
                ABA           => '071025661',
                CheckNumber   => '15',
            },
            'IndustryInfo' => {
                'Type' => 'ECOMMERCE',
            },
        }
    );

    $response->{success}
      ? printf "OK"
      : printf "FAILED (%s)", $response->{error};

=head3 enq

Request information about a previous transaction.

=head4 Required Fields

=over 4

=item TransactionID

transaction id from previous capture or sale transaction.

=back

=head4 Usage

    use Data::Dumper;

    my $response = $ippay->enq(
        {
            TransactionID => '<transaction id>',
        }
    );

    $response->{success}
      ? printf "Ok", dumper($response->{data})
      : printf "Failed (%s)", $response->{error};

=head3 ping

Transaction simply to verify the IPPay service is responsive

=head4 Usage

    my $response = $ippay->ping;
    $response->{success}
      ? printf "Ok", $response->{data}->{ResponseText}
      : printf "Failed (%s)", $response->{error};

=head3 reversal

Reverses a previous CHECK transaction

=head4 Required Fields

=over 4

=item TransactionID

Transaction id from previous capture or sale transaction.

=back

=head4 Usage

    my $response = $ippay->reversal(
        {
            TransactionID => '<transaction id>',
        }
    );

    $response->{success}
      ? printf "Ok"
      : printf "Failed (%s)", $response->{error};

=head3 sale

Equivalent to submitted an authorization (AUTHONLY) and capture (CAPT) 
transaction.

=head4 Required Fields

=over 4

=item CardNum

16 digit credit card number.

=item CardExpMonth

2 digit expiration month.

=item CardExpYear

2 digit expiration year.

=item TotalAmount

Total amount to authorize, as a decimal value (e.g. 12.99).

=back

=head4 Usage

    my $response = $ippay->sale(
        {
            CardNum      => '4000300020001000',
            CardExpMonth => '11',
            CardExpYear  => '14',
            TotalAmount  => 49.00,
        }
    );

    $response->{success}
      ? printf "OK (Transaction ID: %s)", $response->{data}->{TransactionID}
      : printf "FAILED (%s)", $response->{error};

=head3 tokenize

Create a unique Token idenfier that can be used in later transactions in place
of a credit card number or checking/savings account

=head4 Required Fields

=over 4

=item CardNum

16 digit credit card number.

=item CardExpMonth

2 digit expiration month.

=item CardExpYear

2 digit expiration year.

=back

=head4 Usage

    my $response = $ippay->tokenize(
        {
            CardNum      => '4000300020001000',
            CardExpMonth => '11',
            CardExpYear  => '14',
        }
    );

    $response->{success}
      ? printf "OK (Token ID: %s)", $response->{data}->{TokenID}
      : printf "FAILED (%s)", $response->{error};

=head3 void

Voids a credit card transaction before it has been settled (e.g. Card has been 
authorized but not captured yet)

=head4 Required Fields

=over 4

=item TransactionID

Transaction id from previous capture or sale transaction.

=item TotalAmount

The amount authorized in the transaction being voided

=back

=head4 Usage

    my $response = $ippay->void(
        {
            TransactionID => '<transaction id>',
            TotalAmount   => 14.95,
        }
    );

    $response->{success}
      ? printf "Ok"
      : printf "Failed (%s)", $response->{error};

=head3 voidach

Voids a previous check transaction before it has been settled

This transactions requires and accepts all the same fields as the previous
check transaction.

=head4 Usage

    my $response = $ippay->voidach(
        {
            CardName    => 'Test Card',
            TotalAmount => 49.00,
            FeeAmount   => 1.00,
            ACH         => {
                Type          => 'SAVINGS',
                Tokenize      => 'true',
                SEC           => 'PPD',
                AccountNumber => '11111999',
                ABA           => '071025661',
                CheckNumber   => '15',
            },
            'IndustryInfo' => {
                'Type' => 'ECOMMERCE',
            },
        }
    );

    $response->{success}
      ? printf "Ok"
      : printf "Failed (%s)", $response->{error};




=head2 Other Methods

=head3 submit_transaction

Submit a raw transaction to the IPPay API. It is B<recommended> that you use the
various helper methods instead.

=head1 NOTE

=head2 Unimplemented Transactions

=over 4

=item ACK

=item FORCE

=item REVERSEAUTH

=back

=head1 COMPATIBILITY

Compatible with IPPay's XML Product Specification v1.1.6 (Apr 30 2012)

=head1 COPYRIGHT

Copyright 2013 Matt Creenan

This package is free software. You may redistribute it or modify it under
the same terms as Perl itself.

=head1 AUTHORS

Matt Creenan <mattcreenan@gmail.com>

=head1 SEE ALSO

=over 4

=item L<http://www.ippay.com/downloads/IPPay_Reference_Manual.pdf>

=item IPPay XML Product Specification v1.1.6 (no link available)

=item IPPay XML Feature Description for ACH Processing v1.3 (no link available)

=item IPPay Test System and Back-end Simulators v1.3 (no link available)

=back

=cut
