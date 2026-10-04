type BrandLogoProps = {
  iconOnly?: boolean;
  className?: string;
};

export function BrandLogo({ iconOnly = false, className = "" }: BrandLogoProps) {
  return (
    <img
      className={`brandLogo ${iconOnly ? "brandLogoIcon" : ""} ${className}`.trim()}
      src={iconOnly ? "/brand/retailflow-icon-192.png" : "/brand/retailflow-logo.png"}
      alt={iconOnly ? "RetailFlow" : "RetailFlow"}
      width={iconOnly ? 192 : 1200}
      height={iconOnly ? 192 : 355}
    />
  );
}
