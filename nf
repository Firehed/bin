#!/usr/bin/env php
<?php

declare(strict_types=1);

enum TemplateType
{
    case AutoDetect;
    case PlainClass; // class is a reserved name
    case Enum;
    case Trait;
    case Interface;
    case TestCase;
}


function usage() {
    $msg = <<<'FOO'
Usage: %s [-tis] ClassName

    Options:
    -t, --trait: Generate a Trait
    -i, --interface: Generate an Interface
    -e, --enum: Generate an Enum
    -h, --help: Show help and exit

If the class name ends in `Test`, it will be assumed to be a PHPUnit test case
and will automatically extends `\PHPUnit\Framework\TestCase`.

FOO;
    e($msg, $_SERVER['argv'][0]);

}
if ($argc < 2) {
    usage();
}

$nsl = new NamespaceLocator(getcwd());
$info = $nsl->resolve(end($argv));

$builder = new TemplateBuilder($info['fqcn']);
// $builder->setType(FileType::fooBar);
$builder->write(to: $info['file']);
var_dump($info);
exit;

// find composer manifest
$search = getcwd();
while (1) {
	$try = $search.DIRECTORY_SEPARATOR."composer.json";
	if (file_exists($try)) {
		$manifest = file_get_contents($try);
		define('PROJECT_ROOT', $search.DIRECTORY_SEPARATOR);
		break;
	}
	if ($search == DIRECTORY_SEPARATOR) {
		e("composer.json could not be found");
	}
	$search = dirname($search);
}

$data = json_decode($manifest, true);
if (JSON_ERROR_NONE !== json_last_error()) {
	e("Reading composer.json failed");
}
if (!isset($data['autoload']) && !isset($data['autoload-dev'])) {
	e("No autoloader configured in composer.json");
}

$parseLoader = function($autoload) {
    $ns = null;
    if (isset($autoload['psr-4'])) {
        $ns = handlePSR4($autoload['psr-4']);
    } elseif (isset($autoload['psr-0'])) {
        handlePSR0($autload['psr-0']);
    } else {
        e("No PSR-4 or PSR-0 autoload configured");
    }
    return $ns;
};

foreach (['autoload', 'autoload-dev'] as $index) {
    $ns = $parseLoader($data[$index] ?? []);
    if ($ns) break;
}


if (!$ns) {
	e("Current path does not appear to be a defined namespace");
}

$opts = getopt('tieh', ['trait', 'interface', 'enum', 'help']);
if (isset($opts['h']) || isset($opts['help'])) {
    usage();
}
$classname = end($argv);
$is_test = 'Test' == substr($classname, -4);
$is_interface = isset($opts['i']) || isset($opts['interface']) || str_ends_with($classname, 'Interface');
$is_trait = isset($opts['t']) || isset($opts['test']) || str_ends_with($classname, 'Trait');
$is_enum = isset($opts['e']) || isset($opts['enum']) || str_ends_with($classname, 'Enum');

if ($is_trait) $type = 'trait';
elseif ($is_interface) $type = 'interface';
elseif ($is_enum) $type = 'enum';
else $type = 'class';

buildfile($ns, end($argv), $is_test, $type);

function buildfile($ns, $classname, $is_test, $type) {
	if (!is_writable(getcwd())) {
		e("Current directory is not writable");
	}
	$filename = sprintf('%s.php', $classname);
	if (file_exists($filename)) {
		e("File %s already exists!", $filename);
	}
    $strict_types = "\ndeclare(strict_types=1);\n";
	$template = <<<GENPHP
<?php
%s
namespace %s;
%s
%s %s%s
{

}
GENPHP;
	$docblock = '';
	$extends = '';
	if ($is_test) {
		$extends = ' extends \PHPUnit\Framework\TestCase';
		$covered_class = substr($classname, 0, -4); // trim trailing Test
		$docblock = <<<GENPHP

/**
 * @covers $ns\\$covered_class
 */
GENPHP;
	}
	$contents = sprintf($template, $strict_types, $ns, $docblock, $type, $classname, $extends);
	file_put_contents($filename, $contents);
	echo "Wrote generated file to $filename\n";
	exit(0);
}

function handlePSR4(array $configs): ?string
{
	$cwd = getcwd().DIRECTORY_SEPARATOR; // Necessary for root-level dir in NS
	foreach ($configs as $prefix => $pathspecs) {
        $prefix = rtrim($prefix, '\\');
		foreach ((array)$pathspecs as $pathspec) {
			if (!$pathspec) continue; // Ignore empty, it's valid but dumb
			$try = PROJECT_ROOT.$pathspec;
            if (str_starts_with(haystack: $cwd, needle: $try)) {
			// if (0 === strpos($cwd, $try)) {
				$sub = strtr(substr($cwd, strlen($try)), '/', '\\');
				$ns = rtrim($prefix.$sub, '\\'); // trim trailing NS sep
				return $ns;
			}
		}
	}
	return null;
}

function handlePSR0(array $configs) {
	var_dump($configs);
}

function e($msg, ...$args): never
{
	fwrite(STDERR, sprintf($msg, ...$args)."\n");
	exit(1);
}

class NamespaceLocator
{
    /**
     * Absolute path to project root, as defined by presence of composer.json
     */
    private string $projectRoot;
    /**
     * Path from project root (without leading or trailing DS)
     */
    private string $relativeCwd;

    private array $relativeDirectoryToNamespace;

    public function __construct(string $cwd)
    {
        $this->projectRoot = $this->findProjectRoot($cwd);
        $this->relativeCwd = $this->findRelativeCwd($cwd);

        $this->processComposerJson();
    }

    private function findProjectRoot(string $cwd): string
    {
        do {
            $composerJson = $cwd . '/composer.json';
            if (file_exists($composerJson)) {
                return $cwd;
            }
            // Go one higher
            $cwd = dirname($cwd);
        } while ($cwd !== DIRECTORY_SEPARATOR);
        throw new \RuntimeException('composer.json not found all the way up to FS root');
    }

    private function findRelativeCwd(string $cwd): string
    {
        return self::normalizePath(mb_substr($cwd, mb_strlen($this->projectRoot)));
    }

    private function processComposerJson(): void
    {
        $path = $this->projectRoot . '/composer.json';
        $json = file_get_contents($path);
        $data = json_decode($json, true, flags: JSON_THROW_ON_ERROR);

        // FIXME: AKE/autoload

        $psr4Parser = function ($data) {
            foreach ($data as $namespace => $directories) {
                foreach ((array) $directories as $directory) {
                    // var_dump($namespace, $directory);
                    $this->relativeDirectoryToNamespace[self::normalizePath($directory)] = self::normalizePath($namespace);
                }
            }
        };


        // FIXME: AKE/psr-4
        $autoload = $data['autoload']['psr-4'] ?? [];
        $autoloadDev = $data['autoload-dev']['psr-4'] ?? [];
        $psr4Parser($autoload);
        $psr4Parser($autoloadDev);
        // FIXME: warn on PSR-0 presence

        // print_r($this->relativeDirectoryToNamespace);

        /*
        // Figure out NS of rCWD
        foreach ($this->relativeDirectoryToNamespace as $dir => $baseNs) {
            if (str_starts_with(haystack: $this->relativeCwd, needle: $dir)) {
                // We've found a NS root - replace the relative root dir with the NS
                $relativeNs = mb_substr($this->relativeCwd, mb_strlen($dir));
                $fqns = self::pathToNs($baseNs. $relativeNs);
                $this->namespaceOfCwd = $fqns;
                return;
            }
        }
         */
        // Not found - autoloader not available??
        // throw new \RuntimeException('Autoloader not configured for cure


        // var_dump($autoload, $autoloadDev);
    }

    /**
     * @return array{
     *   fqcn: string,
     *   file: string,
     * }
     */
    public function resolve(string $arg): array
    {
        // FIXME: resolve ../ stuff
        $target = $this->relativeCwd . '/' . self::normalizePath($arg);
        foreach ($this->relativeDirectoryToNamespace as $dir => $baseNs) {
            if (str_starts_with(haystack: $target, needle: $dir)) {
                // We've found a NS root - replace the relative root dir with the NS
                $relativeNs = mb_substr($target, mb_strlen($dir));
                $fqcn = self::pathToNs($baseNs . $relativeNs);
                return [
                    'fqcn' => $fqcn,
                    'file' => sprintf('%s/%s.php', $this->projectRoot, $target),
                ];
                var_dump($fqcn, $file, $this->projectRoot);
                exit;
                // return;
            }
        }
        // throw not resolvable
    }

    /**
     * Takes a given path and normalizes it by:
     * - Turning any backslashes to slashes
     * - Removing leading or trailing whitespace
     * - Removing leading or trailing slashes
     */
    private static function normalizePath(string $path): string
    {
        $trimmed = trim($path);
        $slashes = str_replace('\\', '/', $trimmed);
        return trim($slashes, '/');
    }

    private static function pathToNs(string $path): string
    {
        return str_replace('/', '\\', $path);
    }

    private static function getTrailingPathIfLeadingIsSet(string $haystack, string $needle): ?string
    {
        if (!str_starts_with($haystack, $needle)) {
            return null;
        }
    }
}

class TemplateBuilder
{
    // private string $fqcn;
    private TemplateType $type = TemplateType::AutoDetect;
    private bool $strictMode = true; // do not make configurable?

    private string $namespace;
    private string $name;
    private array $uses;


    public function __construct(string $fqcn)
    {
        $components = explode('\\', $fqcn);

        $this->name = array_pop($components);
        $this->namespace = implode('\\', $components);
    }

    /**
     * The type can explicitly be set and will override autodetection
     */
    public function setType(TemplateType $type)
    {
        $this->type = $type;
    }

    private function getTypeName(): string
    {
        return match ($this->type) {
            TemplateType::PlainClass => 'class',
            TemplateType::Enum => 'enum',
            TemplateType::Interface => 'interface',
            TemplateType::Trait => 'trait',
            TemplateType::TestCase => 'class',
            // AutoDetect intentionally excluded
        };
    }

    private function detectType(): TemplateType
    {
        assert($this->type === TemplateType::AutoDetect);
        // TODO: assert name is set ?
        if (str_ends_with($this->name, 'Enum')) {
            return TemplateType::Enum;
        } elseif (str_ends_with($this->name, 'Interface')) {
            return TemplateType::Interface;
        } elseif (str_ends_with($this->name, 'Trait')) {
            return TemplateType::Trait;
        } elseif (str_ends_with($this->name, 'Test')) {
            return TemplateType::TestCase;
        }
        return TemplateType::PlainClass;
    }

    public function write(string $to): void
    {
        echo $this->build();
        // file_put_contents($to, $this->build());
    }

    private function build(): string
    {
        // FIXME: move this check?
        if ($this->type === TemplateType::AutoDetect) {
            $this->type = $this->detectType();
        }

        if ($this->type === TemplateType::TestCase) {
            $extends = 'TestCase';
            $uses = [
                \PHPUnit\Framework\TestCase::class,
                // PHPUnit 10 ~ annotations?
            ];
            $classBeingTested = substr($this->name, 0, -4); // name without Test
            // PHPUnit >= 10
            $attributes = [
                "#[CoversClass({$classBeingTested}::class)]",
            ];
            // PHPUnit < 10
            $annotations = [
                "@covers {$classBeingTested}",
            ];

            var_dump($uses, $attributes, $annotations);
        }

        $tpl = <<<php
        <?php

        declare(strict_types=1);

        namespace {$this->namespace};

        // use here

        {$this->getTypeName()} {$this->name} [extends]
        {
        }
        php;

        print_r($this);

        return $tpl;
    }
}
