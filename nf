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
    private TemplateType $type = TemplateType::AutoDetect;
    private bool $strictMode = true; // do not make configurable?

    private string $namespace;
    private string $name;

    // Metadata
    private array $uses = [];
    private array $annotations = [];
    private array $attributes = [];
    private ?string $extends = null;


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
        file_put_contents($to, $this->build());
    }

    private function build(): string
    {
        // FIXME: move this check?
        if ($this->type === TemplateType::AutoDetect) {
            $this->type = $this->detectType();
        }


        if ($this->type === TemplateType::TestCase) {
            $this->setExtends(\PHPUnit\Framework\TestCase::class);
            $classBeingTested = substr($this->name, 0, -4); // name without Test

            if ($this->shouldUsePHPUnitAttributes()) {
                $this->attributes[] = "#[CoversClass({$classBeingTested}::class)]";
                $this->uses[] = \PHPUnit\Framework\Attributes\CoversClass::class;
            } else {
                $this->annotations[] = "@covers {$classBeingTested}";
            }

        }

        // print_R($this);

        $tpl = <<<php
        <?php

        {$this->buildStrict()}

        namespace {$this->namespace};

        {$this->buildUses()}

        {$this->buildAnnotations()}
        {$this->buildAttributes()}
        {$this->getTypeName()} {$this->name} {$this->buildExtends()}
        {
        }
        php;

        // Collapse consecutive blank lines
        $outputWithoutDupeNewline = preg_replace('/\n\n\n+/', "\n\n", $tpl);
        // Now trim trailing whitespace (note: not \s which grabs newlines too)
        return preg_replace('/\h+$/m', '', $outputWithoutDupeNewline);
    }

    private function buildStrict(): string
    {
        return $this->strictMode ? 'declare(strict_types=1);' : '';
    }

    private function buildUses(): string
    {
        if (!$this->uses) {
            return '';
        }

        $uses = array_map(fn ($fqcn) => "use $fqcn;", $this->uses);
        sort($uses);

        return "\n" . implode("\n", $uses) . "\n";
    }

    private function buildAnnotations(): string
    {
        if (!$this->annotations) {
            return '';
        }
        $formattedAnnotations = array_map(fn ($plain) => ' * ' . $plain, $this->annotations);
        return sprintf("/**\n%s\n */", implode("\n", $formattedAnnotations));
    }
    private function buildAttributes(): string
    {
        if (!$this->attributes) {
            return '';
        }
        sort($this->attributes);
        return implode("\n", $this->attributes);
    }

    private function buildExtends(): string
    {
        if ($this->extends) {
            return sprintf('extends %s', $this->extends);
        }
        return '';
    }

    private function setExtends(string $base): void
    {
        $this->uses[] = $base;
        $parts = explode('\\', $base);
        $this->extends = end($parts);
    }

    private function shouldUsePHPUnitAttributes(): bool
    {
        // FIXME: look at composer.lock and find the version
        return true;
    }
}

function e($msg, ...$args): never
{
	fwrite(STDERR, sprintf($msg, ...$args)."\n");
	exit(1);
}


function usage(): never
{
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

// SCRIPT STARTS HERE

if ($argc < 2) {
    usage();
}

// Read option flags
$opts = getopt('tieh', ['trait', 'interface', 'enum', 'help']);
if (isset($opts['h']) || isset($opts['help'])) {
    usage();
}
$name = end($argv);

$nsl = new NamespaceLocator(getcwd());
$info = $nsl->resolve($name);

$builder = new TemplateBuilder($info['fqcn']);

if (isset($opts['i']) || isset($opts['interface'])) {
    $builder->setType(TemplateType::Interface);
} elseif (isset($opts['t']) || isset($opts['trait'])) {
    $builder->setType(TemplateType::Trait);
} elseif (isset($opts['e']) || isset($opts['enum'])) {
    $builder->setType(TemplateType::Enum);
}

$builder->write(to: $info['file']);

echo "Generated file {$info['file']}\n";
