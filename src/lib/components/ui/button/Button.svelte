<script lang="ts">
	import type { HTMLAnchorAttributes, HTMLButtonAttributes } from 'svelte/elements';

	type ButtonVariant = 'primary' | 'secondary' | 'outline' | 'ghost' | 'destructive' | 'link';
	type ButtonSize = 'sm' | 'md' | 'lg' | 'icon';

	export let variant: ButtonVariant = 'primary';
	export let size: ButtonSize = 'md';
	export let loading = false;
	export let disabled = false;
	export let href: HTMLAnchorAttributes['href'] = undefined;
	export let type: HTMLButtonAttributes['type'] = 'button';
	export let className = '';
	export let ariaLabel: string | undefined = undefined;

	let computedRestProps: Record<string, unknown> = {};
	let restClass = '';
	let restAriaLabel: string | undefined = undefined;

	$: {
		computedRestProps = { ...$$restProps };
		restClass = typeof computedRestProps.class === 'string' ? (computedRestProps.class as string) : '';
		restAriaLabel =
			typeof computedRestProps['aria-label'] === 'string'
				? (computedRestProps['aria-label'] as string)
				: undefined;
		delete computedRestProps.class;
		delete computedRestProps['aria-label'];
	}

	$: isDisabled = disabled || loading;
	$: resolvedAriaLabel = ariaLabel ?? restAriaLabel;

	const sizes: Record<ButtonSize, string> = {
		sm: 'h-9 px-3 text-sm',
		md: 'h-10 px-4 text-sm',
		lg: 'h-11 px-5 text-base',
		icon: 'h-10 w-10'
	};

	const variants: Record<ButtonVariant, string> = {
		primary:
			'bg-brand text-brand-foreground shadow-[0_1px_0_rgba(0,0,0,0.08)] hover:bg-brand-strong active:translate-y-[0.5px] active:shadow-none disabled:opacity-70',
		secondary:
			'bg-gray-100 text-brand-foreground hover:bg-gray-200 dark:bg-gray-850 dark:hover:bg-gray-800 border border-transparent disabled:opacity-60',
		outline:
			'border border-brand-ring text-brand-foreground bg-transparent hover:bg-brand-muted/50 disabled:opacity-60',
		ghost: 'text-brand-foreground hover:bg-gray-100 dark:hover:bg-gray-900 disabled:opacity-60',
		destructive: 'bg-red-600 text-white hover:bg-red-700 disabled:opacity-70',
		link: 'text-brand-foreground underline underline-offset-4 hover:text-brand-strong focus-visible:ring-0 focus-visible:ring-offset-0'
	};

	$: baseClasses =
		'inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-xl text-sm font-semibold transition-all focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-ring focus-visible:ring-offset-2 focus-visible:ring-offset-white dark:focus-visible:ring-offset-gray-950 disabled:cursor-not-allowed';
	$: classes = [baseClasses, variants[variant], sizes[size], restClass, className].filter(Boolean).join(' ');
</script>

<svelte:element
	this={href ? 'a' : 'button'}
	{...computedRestProps}
	class={classes}
	href={href}
	type={href ? undefined : type}
	aria-busy={loading ? 'true' : undefined}
	aria-label={resolvedAriaLabel}
	aria-disabled={isDisabled ? 'true' : undefined}
	disabled={!href && isDisabled ? true : undefined}
	tabindex={href && isDisabled ? -1 : undefined}
>
	{#if loading}
		<span
			class="h-4 w-4 rounded-full border-2 border-brand-ring border-t-transparent animate-spin motion-reduce:hidden"
			aria-hidden="true"
		/>
		<span class="sr-only">Loading</span>
	{/if}
	<slot />
</svelte:element>
