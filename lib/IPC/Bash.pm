package IPC::Bash;

use 5.006;
use strict;
use warnings;

=head1 NAME

IPC::Bash - Library for interracting with bash session 

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';


package Bash;
    use Moose;
    use Mutex;
    use threads;
    use Symbol;
    use MooseX::Privacy;  
    use IPC::Open3;
    use POSIX  qw(mkfifo);
    use File::Temp qw(tempdir :mktemp);
    use File::Spec::Functions;  
    use File::Util::Tempdir qw(get_tempdir get_user_tempdir);
    use Bytes::Random::Secure qw(
        random_bytes_qp random_bytes_base64 random_bytes_hex
    );
    my $sk = 'F' . random_bytes_base64(3) 
             . random_bytes_hex(3);
             
    $sk =~ s/\=//g;
    $sk =~ s/\+//g;
    $sk =~ s/\///g;
    $sk =~ s/\s+//g;
    $sk .= '_';
    
    my $BASH_PROGRAM = <<"string_ending_delimiter";

${sk}input="\${${sk}temp}/output.sock"
${sk}output="\${${sk}temp}/input.sock"
${sk}tempfile="\${${sk}temp}/tempfile.tmp"

${sk}send(){
    echo "\$1" > \${${sk}input}
}

${sk}recv(){
    echo `cat \${${sk}output}`
}


${sk}vartype() {
    local var=\$( declare -p \${1} 2>- || echo '' )

    if [ -z "\${var}" ]; then
        echo "UNDEF"
    else 
        local reg='^declare -n [^=]+=\"([^\"]+)\"\$'
        while [[ \$var =~ \$reg ]]; do
            var=\$( declare -p \${BASH_REMATCH[1]} )
        done
        
        case "\${var#declare -}" in
        a*)
            echo "ARRAY";;
        A*)
            echo "HASH";;
        i*)
            echo "INT";;
        *)
            echo "OTHER";;
        esac
    fi
}

${sk}getvar(){
    local varname="\$1"
    declare -n value="\${varname}"
    local vartype="\$(${sk}vartype \${varname})"
    
    local str=''

    case \${vartype} in 
    
    ARRAY)
        str='['
        for i in "\${value[@]}"
        do
            str="\${str} \$(printf '"%q",' "\${i}") "
        done
        echo "\${str} ]"
    ;;
    
    HASH)
        printf '{'
        for i in \${!value[@]} 
        do
            printf '"%q" => ' "\${i}"
            printf '"%q", ' "\${value[\${i}]}"
        done
        printf '}'
    ;;
    
    INT)
        printf "\${value}"
    ;;
    
    OTHER)
        printf '"%q"' "\${value}"
    ;;
    
    UNDEF)
        printf undef
    ;;
    
    esac
}

${sk}sendvar(){
    b="\${1}"
    c=\$(${sk}getvar "\${b}")
    ${sk}sendarg "\${c}"
}

${sk}sendarg(){
    export ${sk}name="\$1"
}

${sk}exit(){
    kill -9 \$\$
}

${sk}allvars(){
    declare -p | sed  's/^/{ /' | sed 's/\$/ ; } 2>\\&-/';
    alias;
    declare -f;
}

${sk}fork(){
    ${sk}allvars
    echo ${sk}send '0'
    echo ${sk}main
}

${sk}subsh(){
    bash -c "\$(${sk}fork)"
}

${sk}sudo(){
    sudo bash -c "\$(${sk}fork)"
}

${sk}sendexec(){
    c=\$1
    if [[ \$(command -v \${c}) != "" ]]; then
        shift
        c=\$(\${c} "\${@}")
    else 
        c=""
    fi
    ${sk}sendarg "\${c}"
}

${sk}main(){
    while [[ 1 ]]; do
    (
        while [[ 1 ]]; do
            ${sk}u=`(${sk}recv)`
            eval "\${${sk}u}"
            ${sk}send "\${${sk}name}"
            export ${sk}name='0'
        done
    )
        ${sk}send "\${${sk}name}"
    done
}
unset BASH_EXECUTION_STRING;
${sk}main

string_ending_delimiter

    for (qw(temp pid input output thread lockcmd)){
        has $_ => (
            is => 'rw',
            traits => ['Private'],
        );
    };
    
    sub key{
        return $sk;
    }
    
    sub exit{
        return $_[0]->runcmd($sk . 'exit');
    }
    
    sub getvar{
        return eval($_[0]->runcmd($sk . 'sendvar ' . $_[1]));
    }
    
    sub subsh{
        return $_[0]->runcmd($sk . 'subsh');
    }
    
    sub sudo{
        return $_[0]->runcmd($sk . 'sudo');
    }

    sub join{
        return $_[0]->thread->join;
    }
    
    sub execfunc{
        return $_[0]->runcmd($sk . 'sendexec ' . $_[1]);        
    }
    
    private_method flush => sub{
        my $self = shift;
        open (my $hd1, "+<", $self->input);
        syswrite $hd1, "", 0;
        open (my $hd2, "+<", $self->output);
        syswrite $hd2, "", 0;
    };
    
    sub close {
        my $self = shift;
        my $pid = $self->pid;
        if ( defined $pid){
            kill 9, $pid;
            $self->flush;
            $self->pid(undef);
            $self->thread()->join();
            $self->thread(undef);
        }
    }
    
    private_method open => sub {
        my $self = shift;
        my $pid = $self->pid();
        if (! defined $pid ){
            mkfifo($self->input, 0777);
            mkfifo($self->output, 0777);
            my $name = $self->temp;
            my $pid = open3('<STDIN', '>&STDOUT', '>&STDERR',
                'env', "${sk}temp=$name", 
                'bash', '-c', $BASH_PROGRAM);
            my $th = threads->create(
            sub{
                waitpid $pid, 0;
                $self->flush();
                $self->close();
            });
            $self->thread($th);
            $self->pid($pid);
        } 
    };
    
    sub runcmd{
        my $self = shift;
        my $data = shift;
        my $mutex = $self->lockcmd;
        
        $mutex->lock;
        
        $self->open;
        $self->send ($data);
        
        $data = $self->recv;
        
        $mutex->unlock;
        
        return $data;
    }
    
    private_method send => sub {
        my $self = shift;
        my $data = shift;
        my $file = $self->input;
        my $handle1 = gensym;
        CORE::open ($handle1, ">" . $file);
        CORE::syswrite $handle1, $data, length $data;
        CORE::close $handle1;
    };
    
    private_method recv => sub {
        my $self = shift;
        my $file = $self->output;
        my $data;
        my $handle2 = gensym;
        CORE::open($handle2, "<" . $file);
        CORE::sysread $handle2, $data, 9999;
        CORE::close $handle2;
        return $data;
    };


=head1 SYNOPSIS

This module will span an bash session

Little code snippet.

    use IPC::Bash;

    my $foo = IPC::Bash->new();
    ...

=head1 SUBROUTINES/METHODS

=head2 exit()
    exit from current subshell
    
=head2 subsh()
    call subshell
    
=head2 sudo()
    call subshell with sudo

=head2 getvar(I<name>)
    get variable value

=head2 key()
    get subshell key
    
=head2 join()
    wait until session closed
    
=head2 execfunc(I<name>)
    get function output
    
=head2 close()
    close bash session
    
=head2 runcmd(I<str>)
    run session command
    
=head2 
=cut


    sub BUILDARGS{
        my $temp =  mkdtemp(catfile(get_user_tempdir(), ${sk}."XXXXXXXX"));
        my $input = catfile($temp, 'input.sock');
        my $output = catfile($temp, 'output.sock');
        return {
            'temp', $temp,
            'input', $input,
            'output', $output,
            'lockcmd', Mutex->new,
        };
    }
    1;


=head1 AUTHOR

huakim-tyk, C<< <zuhhaga at gmail.com> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-ipc-bash at rt.cpan.org>, or through
the web interface at L<https://rt.cpan.org/NoAuth/ReportBug.html?Queue=IPC-Bash>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc IPC::Bash


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<https://rt.cpan.org/NoAuth/Bugs.html?Dist=IPC-Bash>

=item * CPAN Ratings

L<https://cpanratings.perl.org/d/IPC-Bash>

=item * Search CPAN

L<https://metacpan.org/release/IPC-Bash>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2023 by huakim-tyk.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)


=cut

1; # End of IPC::Bash
